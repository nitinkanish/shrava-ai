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
    /// Long-meeting windows: 8 minutes with 20s overlap (avoids OOM on multi-hour files).
    public static let longMeetingWindowSeconds: Double = 8 * 60
    public static let longMeetingOverlapSeconds: Double = 20
    /// Prefer streaming windows instead of a single in-memory whole-file pass above this duration.
    public static let longMeetingThresholdSeconds: Double = 10 * 60

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

    /// Overlapping windows for long audio. Step = window − overlap; last window is clipped to EOF.
    public static func overlappingFrameRanges(
        totalFrames: Int64,
        sampleRate: Double,
        windowSeconds: Double = longMeetingWindowSeconds,
        overlapSeconds: Double = longMeetingOverlapSeconds
    ) -> [(start: Int64, count: Int64)] {
        guard totalFrames > 0, sampleRate > 0, windowSeconds > 0 else { return [] }
        let windowFrames = max(Int64(1), Int64(sampleRate * windowSeconds))
        let overlapFrames = max(Int64(0), min(windowFrames - 1, Int64(sampleRate * max(0, overlapSeconds))))
        let step = max(Int64(1), windowFrames - overlapFrames)
        var ranges: [(Int64, Int64)] = []
        var start: Int64 = 0
        while start < totalFrames {
            let count = min(windowFrames, totalFrames - start)
            ranges.append((start, count))
            if start + count >= totalFrames { break }
            start += step
        }
        return ranges
    }

    /// Join chunk transcripts, dropping repeated lead-in words that came from the overlap region.
    public static func stitchChunkTexts(_ parts: [String], overlapWordHint: Int = 16) -> String {
        var out: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let prev = out.last, overlapWordHint > 0 else {
                out.append(trimmed)
                continue
            }
            out.append(dropOverlappingPrefix(of: trimmed, after: prev, maxWords: overlapWordHint))
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dropOverlappingPrefix(of next: String, after previous: String, maxWords: Int) -> String {
        let prevWords = previous.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        let nextWords = next.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard !prevWords.isEmpty, !nextWords.isEmpty else { return next }
        let maxCheck = min(maxWords, prevWords.count, nextWords.count)
        var best = 0
        for n in stride(from: maxCheck, through: 2, by: -1) {
            let suffix = prevWords.suffix(n).map { $0.lowercased() }
            let prefix = nextWords.prefix(n).map { $0.lowercased() }
            if Array(suffix) == Array(prefix) {
                best = n
                break
            }
        }
        if best == 0 { return next }
        return nextWords.dropFirst(best).joined(separator: " ")
    }
}
