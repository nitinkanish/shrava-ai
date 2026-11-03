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

        public init(timerStart: Date = Date(), isPaused: Bool = false, frozenElapsed: TimeInterval = 0) {
            self.timerStart = timerStart
            self.isPaused = isPaused
            self.frozenElapsed = frozenElapsed
        }
    }

    public var title: String

    public init(title: String = "Meeting") {
        self.title = title
    }
}
#endif
