import Foundation
import AVFoundation

enum RecordingMode: Equatable {
    case quick   // short hold-to-talk WAV PCM 16 kHz
    case long    // meeting AAC m4a, background-safe
}

final class IOSAudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private(set) var recordingURL: URL?
    private(set) var mode: RecordingMode = .quick
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var wasInterrupted = false

    /// Normalized 0...1 level from the recorder meters.
    var normalizedLevel: Float {
        guard let audioRecorder, audioRecorder.isRecording else { return 0 }
        audioRecorder.updateMeters()
        let power = audioRecorder.averagePower(forChannel: 0)
        let clamped = max(-50, min(0, power))
        return (clamped + 50) / 50
    }

    var isRecording: Bool { audioRecorder?.isRecording == true }
    var isPaused: Bool {
        guard let audioRecorder, recordingURL != nil else { return false }
        return !audioRecorder.isRecording && wasInterrupted == false && audioRecorder.currentTime > 0
    }

    func startRecording(mode: RecordingMode = .quick) async throws {
        self.mode = mode
        try configureSession(for: mode)

        let ext = mode == .long ? "m4a" : "wav"
        let dir: URL
        if mode == .long {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            dir = docs
        } else {
            dir = FileManager.default.temporaryDirectory
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".\(ext)")
        recordingURL = url

        let settings: [String: Any]
        switch mode {
        case .quick:
            settings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        case .long:
            // AAC writes incrementally to file — safe for multi-hour meetings.
            settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
        }

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            audioRecorder = recorder
            guard recorder.record() else {
                throw RecordingError.failedToStart(NSError(domain: "IOSAudioRecorder", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "AVAudioRecorder failed to start"
                ]))
            }
            installSessionObservers()
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.failedToStart(error)
        }
    }

    func pause() {
        guard mode == .long, let audioRecorder, audioRecorder.isRecording else { return }
        audioRecorder.pause()
    }

    func resume() throws {
        guard mode == .long, let audioRecorder, !audioRecorder.isRecording else { return }
        try configureSession(for: .long)
        guard audioRecorder.record() else {
            throw RecordingError.failedToStart(NSError(domain: "IOSAudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to resume recording"
            ]))
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Stops and returns in-memory data (quick mode). Deletes temp file.
    func stopRecording() -> Data? {
        audioRecorder?.stop()
        audioRecorder = nil
        removeSessionObservers()
        deactivateSession()

        guard let url = recordingURL else { return nil }
        defer {
            if mode == .quick {
                try? FileManager.default.removeItem(at: url)
            }
            recordingURL = nil
        }
        return try? Data(contentsOf: url)
    }

    /// Stops long recording and returns the file URL (caller owns the file).
    func stopLongRecording() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        removeSessionObservers()
        // Keep session active briefly until Live Activity ends — caller deactivates via deactivateAfterStop.
        let url = recordingURL
        recordingURL = nil
        return url
    }

    /// Call after Live Activity has ended so AudioRecordingIntent contract is satisfied.
    func deactivateAfterStop() {
        deactivateSession()
    }

    func cancelRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        removeSessionObservers()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
        deactivateSession()
    }

    // MARK: - Session

    private func configureSession(for mode: RecordingMode) throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + default mode keeps mic alive in background when UIBackgroundModes includes audio.
        try session.setCategory(
            .playAndRecord,
            mode: mode == .long ? .default : .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
    }

    private func installSessionObservers() {
        removeSessionObservers()
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    private func removeSessionObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            wasInterrupted = true
            audioRecorder?.pause()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            wasInterrupted = false
            if options.contains(.shouldResume), mode == .long {
                try? configureSession(for: .long)
                _ = audioRecorder?.record()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard mode == .long,
              let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // Keep going after route changes (Bluetooth connect/disconnect).
        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            try? configureSession(for: .long)
            if audioRecorder?.isRecording == false, !wasInterrupted {
                _ = audioRecorder?.record()
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("AVAudioRecorder encode error: \(error?.localizedDescription ?? "unknown")")
    }
}

enum RecordingError: Error {
    case failedToStart(Error)
    case noPermission
}
