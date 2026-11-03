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
    
    func startRecording() async throws {
        let url = FileManager.default.temporaryDirectory
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
    
    func stopRecording() -> Data? {
        LevelMeter.recorder = nil
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
