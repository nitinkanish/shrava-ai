import Foundation
#if os(iOS)
import AppIntents

extension Notification.Name {
    static let shravaStopLongRecording = Notification.Name("com.shrava.stopLongRecording")
}

/// Stop button on the Dynamic Island / Lock Screen Live Activity.
/// Runs in the app process (`openAppWhenRun`) so it can signal IOSAppState.
@available(iOS 16.1, *)
public struct StopRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Stop Recording"
    public static var description = IntentDescription("Stop the current Shrava long recording and transcribe it.")
    public static var openAppWhenRun: Bool { true }

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .shravaStopLongRecording, object: nil)
        }
        return .result()
    }
}
#endif
