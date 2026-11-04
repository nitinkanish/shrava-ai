import Foundation
import AVFoundation

enum LevelMeter {
    nonisolated(unsafe) static var recorder: AVAudioRecorder?
    /// 0...1 normalised input level
    static func level() -> CGFloat {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        return CGFloat(max(0, min(1, (db + 55) / 50)))
    }
}

actor AudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    private static var recordingsDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    func startRecording() async throws {
        let url = Self.recordingsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        recordingURL = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            LevelMeter.recorder = audioRecorder
        } catch {
            throw RecordingError.failedToStart(error)
        }
    }
    
    /// Stops recording and returns PCM data + on-disk URL (kept under Application Support/Shrava/Recordings).
    func stopRecording() -> (data: Data, url: URL)? {
        LevelMeter.recorder = nil
        audioRecorder?.stop()
        audioRecorder = nil
        
        guard let url = recordingURL else { return nil }
        recordingURL = nil
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, url)
    }
    
    func cancelRecording() {
        LevelMeter.recorder = nil
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
