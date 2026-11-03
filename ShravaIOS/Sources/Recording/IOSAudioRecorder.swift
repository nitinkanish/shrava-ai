import Foundation
import AVFoundation

enum RecordingMode: Equatable {
    case quick   // short hold-to-talk WAV PCM 16 kHz
    case long    // meeting AAC m4a, background-safe
}

enum RecordingPauseReason: Equatable {
    case phoneCall
    case audioInterruption
    case routeChange
    case manual

    var liveActivityMessage: String {
        switch self {
        case .phoneCall: return "Paused — call in progress"
        case .audioInterruption: return "Paused — audio interrupted"
        case .routeChange: return "Paused — audio route changed"
        case .manual: return "Paused"
        }
    }

    var transcriptGapMarker: String? {
        switch self {
        case .phoneCall:
            return "[Recording paused during phone call]"
        case .audioInterruption, .routeChange:
            return "[Recording paused — audio interrupted]"
        case .manual:
            return nil
        }
    }
}

/// Events surfaced to IOSAppState (pause UI, Live Activity, gap markers).
protocol IOSAudioRecorderDelegate: AnyObject {
    func audioRecorderDidBeginInterruption(_ recorder: IOSAudioRecorder, reason: RecordingPauseReason)
    func audioRecorderDidResume(_ recorder: IOSAudioRecorder)
    func audioRecorderResumeFailed(_ recorder: IOSAudioRecorder, error: Error, willRetry: Bool)
}

final class IOSAudioRecorder: NSObject, AVAudioRecorderDelegate {
    weak var delegate: IOSAudioRecorderDelegate?

    private var audioRecorder: AVAudioRecorder?
    private(set) var recordingURL: URL?
    /// Completed segment files (when a new segment was required after a hard interrupt).
    private(set) var completedSegmentURLs: [URL] = []
    private(set) var mode: RecordingMode = .quick
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var wasInterrupted = false
    private var pauseReason: RecordingPauseReason?
    private var resumeWorkItem: DispatchWorkItem?
    private var resumeAttempt = 0
    private let maxResumeAttempts = 30          // ~60s with backoff
    private var isStopping = false
    private var longRecordingDirectory: URL?

    /// Normalized 0...1 level from the recorder meters.
    var normalizedLevel: Float {
        guard let audioRecorder, audioRecorder.isRecording else { return 0 }
        audioRecorder.updateMeters()
        let power = audioRecorder.averagePower(forChannel: 0)
        let clamped = max(-50, min(0, power))
        return (clamped + 50) / 50
    }

    var isRecording: Bool { audioRecorder?.isRecording == true }

    /// True when we have an open long-recording file that is currently paused (interrupt or manual).
    var isPausedRecording: Bool {
        guard mode == .long, recordingURL != nil, let audioRecorder else { return false }
        return !audioRecorder.isRecording
    }

    var currentPauseReason: RecordingPauseReason? { pauseReason }

    // MARK: - Start

    func startRecording(mode: RecordingMode = .quick) async throws {
        self.mode = mode
        self.isStopping = false
        self.wasInterrupted = false
        self.pauseReason = nil
        self.resumeAttempt = 0
        self.completedSegmentURLs = []
        cancelResumeRetries()

        try await activateSession(for: mode, allowingRetries: mode == .long)

        let ext = mode == .long ? "m4a" : "wav"
        let dir: URL
        if mode == .long {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            dir = docs
            longRecordingDirectory = docs
        } else {
            dir = FileManager.default.temporaryDirectory
            longRecordingDirectory = nil
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".\(ext)")
        recordingURL = url

        let recorder = try makeRecorder(url: url, mode: mode)
        audioRecorder = recorder
        guard recorder.record() else {
            throw RecordingError.failedToStart(Self.makeError(-1, "AVAudioRecorder failed to start"))
        }
        installSessionObservers()
    }

    // MARK: - Pause / Resume

    func pause(reason: RecordingPauseReason = .manual) {
        guard mode == .long else { return }
        cancelResumeRetries()
        let alreadyPaused = audioRecorder?.isRecording == false && recordingURL != nil
        if audioRecorder?.isRecording == true {
            audioRecorder?.pause()
        }
        wasInterrupted = reason != .manual
        let previous = pauseReason
        pauseReason = reason
        // Skip duplicate delegate noise when CallKit + interruption both fire for the same call.
        if alreadyPaused, previous == reason { return }
        delegate?.audioRecorderDidBeginInterruption(self, reason: reason)
    }

    /// Attempt to resume into the same file; on hard failure, open a new segment.
    func resume(reasonCleared: Bool = true) throws {
        guard mode == .long else { return }
        guard recordingURL != nil || !completedSegmentURLs.isEmpty else { return }
        cancelResumeRetries()

        try activateSessionSync(for: .long)

        if let audioRecorder, !audioRecorder.isRecording {
            if audioRecorder.record() {
                finishSuccessfulResume(reasonCleared: reasonCleared)
                return
            }
        }

        // Recorder may be dead after a call — roll a new segment, keep prior audio.
        try startNewSegmentContinuing()
        finishSuccessfulResume(reasonCleared: reasonCleared)
    }

    /// Non-throwing resume with retry/backoff (used after calls / interruptions).
    func resumeWithRetry(trigger: String) {
        guard mode == .long, !isStopping else { return }
        cancelResumeRetries()
        resumeAttempt = 0
        scheduleResumeAttempt(trigger: trigger)
    }

    private func scheduleResumeAttempt(trigger: String) {
        guard mode == .long, !isStopping else { return }
        if audioRecorder?.isRecording == true {
            finishSuccessfulResume(reasonCleared: true)
            return
        }

        resumeAttempt += 1
        let attempt = resumeAttempt
        do {
            try resume(reasonCleared: true)
            print("IOSAudioRecorder resumed after \(trigger) on attempt \(attempt)")
            return
        } catch {
            let willRetry = attempt < maxResumeAttempts
            print("IOSAudioRecorder resume failed (\(trigger)) attempt \(attempt): \(error.localizedDescription); retry=\(willRetry)")
            delegate?.audioRecorderResumeFailed(self, error: error, willRetry: willRetry)
            guard willRetry else { return }
            // Backoff: 0.5, 1, 1.5, … capped at 2s → ~60s total window.
            let delay = min(2.0, 0.5 * Double(attempt))
            let work = DispatchWorkItem { [weak self] in
                self?.scheduleResumeAttempt(trigger: trigger)
            }
            resumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func finishSuccessfulResume(reasonCleared: Bool) {
        wasInterrupted = false
        if reasonCleared { pauseReason = nil }
        resumeAttempt = 0
        cancelResumeRetries()
        delegate?.audioRecorderDidResume(self)
    }

    private func startNewSegmentContinuing() throws {
        // Finalize current recorder without deactivating session / clearing history.
        if let audioRecorder {
            audioRecorder.stop()
            self.audioRecorder = nil
        }
        if let url = recordingURL {
            // Only keep non-empty segments.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 {
                completedSegmentURLs.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let dir = longRecordingDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        recordingURL = url
        let recorder = try makeRecorder(url: url, mode: .long)
        audioRecorder = recorder
        guard recorder.record() else {
            throw RecordingError.failedToStart(Self.makeError(-2, "Failed to start new recording segment"))
        }
    }

    // MARK: - Stop

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Stops and returns in-memory data (quick mode). Deletes temp file.
    func stopRecording() -> Data? {
        isStopping = true
        cancelResumeRetries()
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

    /// Stops long recording and returns a single file URL (concatenates segments if needed).
    func stopLongRecording() async -> URL? {
        isStopping = true
        cancelResumeRetries()
        audioRecorder?.stop()
        audioRecorder = nil
        removeSessionObservers()

        var segments = completedSegmentURLs
        if let url = recordingURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 { segments.append(url) }
            else { try? FileManager.default.removeItem(at: url) }
        }
        recordingURL = nil
        completedSegmentURLs = []

        guard !segments.isEmpty else { return nil }
        if segments.count == 1 { return segments[0] }

        let out = (longRecordingDirectory
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString + "-merged.m4a")
        if await mergeSegments(segments, into: out) {
            for s in segments { try? FileManager.default.removeItem(at: s) }
            return out
        }
        // Fallback: return the longest segment so we never lose everything.
        return segments.max(by: { a, b in
            let sa = (try? FileManager.default.attributesOfItem(atPath: a.path)[.size] as? NSNumber)?.intValue ?? 0
            let sb = (try? FileManager.default.attributesOfItem(atPath: b.path)[.size] as? NSNumber)?.intValue ?? 0
            return sa < sb
        })
    }

    func deactivateAfterStop() {
        deactivateSession()
    }

    func cancelRecording() {
        isStopping = true
        cancelResumeRetries()
        audioRecorder?.stop()
        audioRecorder = nil
        removeSessionObservers()
        var urls = completedSegmentURLs
        if let recordingURL { urls.append(recordingURL) }
        for u in urls { try? FileManager.default.removeItem(at: u) }
        completedSegmentURLs = []
        recordingURL = nil
        deactivateSession()
    }

    // MARK: - Session

    /// Prefer exclusive playAndRecord for long meetings (no mixWithOthers) so background audio mode keeps the mic.
    /// Drop mixWithOthers — mixing with a phone call still can't capture call audio, and exclusive category
    /// resumes more reliably after CallKit releases the session.
    private func activateSession(for mode: RecordingMode, allowingRetries: Bool) async throws {
        var lastError: Error?
        let attempts = allowingRetries ? 8 : 1
        for i in 0..<attempts {
            do {
                try activateSessionSync(for: mode)
                return
            } catch {
                lastError = error
                // Transient failures while a call / Siri / other audio owns the session.
                if !allowingRetries { break }
                let delay = UInt64(250_000_000 * (i + 1)) // 0.25s, 0.5s, …
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw RecordingError.failedToStart(lastError ?? Self.makeError(-10, "Session activation failed"))
    }

    private func activateSessionSync(for mode: RecordingMode) throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions
        let sessionMode: AVAudioSession.Mode
        switch mode {
        case .long:
            // spokenAudio is appropriate for meeting capture; default is also fine.
            sessionMode = .spokenAudio
            options = [.allowBluetoothHFP, .defaultToSpeaker]
        case .quick:
            sessionMode = .measurement
            options = [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        }
        try session.setCategory(.playAndRecord, mode: sessionMode, options: options)
        try session.setActive(true, options: [])
    }

    private func makeRecorder(url: URL, mode: RecordingMode) throws -> AVAudioRecorder {
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
            settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
        }
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        return recorder
    }

    // MARK: - Observers

    private func installSessionObservers() {
        removeSessionObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
        mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.mode == .long, !self.isStopping else { return }
            self.pause(reason: .audioInterruption)
            self.resumeWithRetry(trigger: "mediaReset")
        }
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        if let routeObserver { center.removeObserver(routeObserver) }
        if let mediaResetObserver { center.removeObserver(mediaResetObserver) }
        interruptionObserver = nil
        routeObserver = nil
        mediaResetObserver = nil
    }

    private func cancelResumeRetries() {
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard mode == .long, !isStopping else { return }
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Keep the file; pause only. Phone calls / FaceTime take the mic — we cannot record them.
            wasInterrupted = true
            let reason: RecordingPauseReason =
                PhoneCallMonitor.shared.hasActiveCall ? .phoneCall : .audioInterruption
            pauseReason = reason
            if audioRecorder?.isRecording == true {
                audioRecorder?.pause()
            }
            cancelResumeRetries()
            delegate?.audioRecorderDidBeginInterruption(self, reason: reason)

        case .ended:
            // Phone calls often omit shouldResume — always try to resume for long recordings.
            wasInterrupted = false
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            let should = options.contains(.shouldResume)
            print("IOSAudioRecorder interruption ended shouldResume=\(should) — scheduling resume")
            resumeWithRetry(trigger: "interruptionEnded")

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard mode == .long, !isStopping else { return }
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable, .categoryChange, .override:
            if audioRecorder?.isRecording == false {
                resumeWithRetry(trigger: "routeChange-\(reason.rawValue)")
            }
        default:
            break
        }
    }

    // MARK: - Merge

    private func mergeSegments(_ urls: [URL], into output: URL) async -> Bool {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return false }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            do {
                let assetTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let assetTrack = assetTracks.first else { continue }
                let duration = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
            } catch {
                print("mergeSegments insert failed: \(error)")
                return false
            }
        }
        guard cursor > .zero else { return false }

        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        do {
            try await exporter.export(to: output, as: .m4a)
            return FileManager.default.fileExists(atPath: output.path)
        } catch {
            print("merge export failed: \(error)")
            return false
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("AVAudioRecorder encode error: \(error?.localizedDescription ?? "unknown")")
        guard mode == .long, !isStopping else { return }
        // Keep audio already on disk; open a fresh segment when possible.
        pause(reason: .audioInterruption)
        resumeWithRetry(trigger: "encodeError")
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Unexpected finish (e.g. system killed recorder during call) — keep file, try new segment later.
        guard mode == .long, !isStopping, !flag else { return }
        print("AVAudioRecorder finished unexpectedly (success=\(flag))")
        wasInterrupted = true
        pauseReason = .audioInterruption
        delegate?.audioRecorderDidBeginInterruption(self, reason: .audioInterruption)
    }

    private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "IOSAudioRecorder", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum RecordingError: Error, LocalizedError {
    case failedToStart(Error)
    case noPermission
    case callInProgress

    var errorDescription: String? {
        switch self {
        case .failedToStart(let e): return e.localizedDescription
        case .noPermission: return "Microphone permission not granted"
        case .callInProgress: return "Can't record during a phone call — will start when the call ends"
        }
    }
}
