import Foundation
import AVFoundation

actor IOSAudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    
    func startRecording() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        recordingURL = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
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
