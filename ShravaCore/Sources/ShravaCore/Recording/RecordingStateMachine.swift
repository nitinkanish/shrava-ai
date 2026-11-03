import Foundation

/// Pure recording lifecycle used by unit tests and as the source of truth for allowed transitions.
public enum RecordingPhase: String, Codable, Sendable, Equatable {
    case idle
    case recording
    case paused
    case interrupted
    case stopping
    case transcribing
    case saved
    case failed
}

public enum RecordingEvent: Sendable, Equatable {
    case start
    case pause
    case resume
    case stop
    case interrupt
    case callEnded
    case transcriptionStarted
    case transcriptionSucceeded
    case transcriptionFailed
    case reset
}

public enum RecordingStateMachine {
    public static func reduce(phase: RecordingPhase, event: RecordingEvent) -> RecordingPhase {
        switch (phase, event) {
        case (.idle, .start): return .recording
        case (.recording, .pause), (.recording, .interrupt): return .paused
        case (.recording, .stop): return .stopping
        case (.paused, .resume), (.paused, .callEnded): return .recording
        case (.paused, .stop): return .stopping
        case (.interrupted, .callEnded), (.interrupted, .resume): return .recording
        case (.interrupted, .stop): return .stopping
        case (.stopping, .transcriptionStarted): return .transcribing
        case (.transcribing, .transcriptionSucceeded): return .saved
        case (.transcribing, .transcriptionFailed): return .failed
        case (.saved, .reset), (.failed, .reset), (.idle, .reset): return .idle
        case (.failed, .start): return .recording
        case (.saved, .start): return .recording
        default: return phase
        }
    }

    public static func canStart(from phase: RecordingPhase) -> Bool {
        phase == .idle || phase == .saved || phase == .failed
    }
}

/// Schedules Whisper work into fixed-duration chunks (pure helper for tests / resume math).
public enum TranscriptChunkScheduler {
    public static func chunkCount(durationSeconds: Double, chunkSeconds: Double = 30) -> Int {
        guard durationSeconds > 0, chunkSeconds > 0 else { return 1 }
        return max(1, Int(ceil(durationSeconds / chunkSeconds)))
    }

    public static func frameRanges(totalFrames: Int64, sampleRate: Double, chunkSeconds: Double = 30) -> [(start: Int64, count: Int64)] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let chunkFrames = Int64(sampleRate * chunkSeconds)
        var ranges: [(Int64, Int64)] = []
        var start: Int64 = 0
        while start < totalFrames {
            let count = min(chunkFrames, totalFrames - start)
            ranges.append((start, count))
            start += count
        }
        return ranges
    }
}
