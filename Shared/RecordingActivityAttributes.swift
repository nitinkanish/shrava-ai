import Foundation
#if os(iOS)
import ActivityKit

/// Shared between ShravaIOS and the Live Activity widget extension.
public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock moment recording (or current resume) began for live timer.
        public var timerStart: Date
        public var isPaused: Bool
        /// Frozen elapsed seconds while paused (for display).
        public var frozenElapsed: TimeInterval
        /// Optional status line while paused (e.g. "Paused — call in progress").
        public var pauseReason: String?

        public init(
            timerStart: Date = Date(),
            isPaused: Bool = false,
            frozenElapsed: TimeInterval = 0,
            pauseReason: String? = nil
        ) {
            self.timerStart = timerStart
            self.isPaused = isPaused
            self.frozenElapsed = frozenElapsed
            self.pauseReason = pauseReason
        }
    }

    public var title: String

    public init(title: String = "Meeting") {
        self.title = title
    }
}
#endif
