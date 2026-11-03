import Foundation
import AVFoundation

final class IOSAudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    func startRecording() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        recordingURL = url

        // 16 kHz mono linear PCM — matches Whisper's expected input (resampled to float in IOSWhisper).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            guard audioRecorder?.record() == true else {
                throw RecordingError.failedToStart(NSError(domain: "IOSAudioRecorder", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "AVAudioRecorder failed to start"
                ]))
            }
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.failedToStart(error)
        }
    }

    func stopRecording() -> Data? {
        audioRecorder?.stop()
        audioRecorder = nil

        guard let url = recordingURL else { return nil }

        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        return try? Data(contentsOf: url)
    }

    func cancelRecording() {
        audioRecorder?.stop()
        audioRecorder = nil

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}

enum RecordingError: Error {
    case failedToStart(Error)
    case noPermission
}
