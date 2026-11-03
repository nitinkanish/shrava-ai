import Foundation
#if os(iOS)
import ActivityKit

/// Shared between ShravaIOS and the Live Activity widget extension.
public struct RecordingActivityAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable, Sendable {
        case recording
        case paused
        case transcribing
        case saved
        case failed
    }

    public struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock moment recording (or current resume) began for live timer.
        public var timerStart: Date
        public var isPaused: Bool
        /// Frozen elapsed seconds while paused / post-stop (for display).
        public var frozenElapsed: TimeInterval
        /// Optional status line (pause reason, Transcribing…, Saved ✓, error).
        public var pauseReason: String?
        /// Lifecycle phase — drives Island / Lock Screen chrome.
        public var phase: Phase
        /// 0…1 while `phase == .transcribing`.
        public var progress: Double

        public init(
            timerStart: Date = Date(),
            isPaused: Bool = false,
            frozenElapsed: TimeInterval = 0,
            pauseReason: String? = nil,
            phase: Phase = .recording,
            progress: Double = 0
        ) {
            self.timerStart = timerStart
            self.isPaused = isPaused
            self.frozenElapsed = frozenElapsed
            self.pauseReason = pauseReason
            self.phase = phase
            self.progress = progress
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timerStart = try c.decodeIfPresent(Date.self, forKey: .timerStart) ?? Date()
            isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            frozenElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .frozenElapsed) ?? 0
            pauseReason = try c.decodeIfPresent(String.self, forKey: .pauseReason)
            progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            if let p = try c.decodeIfPresent(Phase.self, forKey: .phase) {
                phase = p
            } else if isPaused {
                phase = .paused
            } else {
                phase = .recording
            }
        }

        enum CodingKeys: String, CodingKey {
            case timerStart, isPaused, frozenElapsed, pauseReason, phase, progress
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(timerStart, forKey: .timerStart)
            try c.encode(isPaused, forKey: .isPaused)
            try c.encode(frozenElapsed, forKey: .frozenElapsed)
            try c.encodeIfPresent(pauseReason, forKey: .pauseReason)
            try c.encode(phase, forKey: .phase)
            try c.encode(progress, forKey: .progress)
        }
    }

    public var title: String

    public init(title: String = "Meeting") {
        self.title = title
    }
}
#endif
