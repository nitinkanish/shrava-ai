import Foundation
import AppIntents
import ActivityKit

#if os(iOS)

// MARK: - Bridge (intents ↔ app process via LiveActivityIntent routing)

enum RecordingIntentAction: String {
    case start
    case stop
    case toggle
}

enum ShravaControlKind {
    /// Control Center control kind — keep in sync with ShravaRecordingControl.
    static let recording = "com.shrava.ios.recording-control"
}

extension Notification.Name {
    /// Posted by intents; observed by IOSAppState in the app process.
    static let shravaRecordingIntent = Notification.Name("com.shrava.recordingIntent")
    /// Posted by IOSAppState when start/stop has settled (or failed).
    static let shravaRecordingIntentSettled = Notification.Name("com.shrava.recordingIntentSettled")
}

/// Waits inside `perform()` so AudioRecordingIntent’s mic grant stays open until recording actually starts.
enum RecordingIntentBridge {
    static let timeout: TimeInterval = 10

    @discardableResult
    static func dispatchAndWait(action: RecordingIntentAction) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let lock = NSLock()
            var finished = false
            var token: NSObjectProtocol?

            let finish: (String) -> Void = { reason in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume(returning: reason)
            }

            token = NotificationCenter.default.addObserver(
                forName: .shravaRecordingIntentSettled,
                object: nil,
                queue: nil
            ) { note in
                let reason = (note.userInfo?["reason"] as? String) ?? "ok"
                finish(reason)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish("timeout")
            }

            NotificationCenter.default.post(
                name: .shravaRecordingIntent,
                object: nil,
                userInfo: ["action": action.rawValue]
            )
        }
    }

    static func settle(reason: String = "ok") {
        NotificationCenter.default.post(
            name: .shravaRecordingIntentSettled,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    /// True when a Shrava recording Live Activity is active (works in app + extension).
    static var isLiveRecordingActive: Bool {
        !Activity<RecordingActivityAttributes>.activities.isEmpty
    }
}

// MARK: - Intents

/// Start a long meeting recording without opening the app (Action Button / Shortcuts / Siri).
@available(iOS 18.0, *)
public struct StartRecordingIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Start Shrava Recording"
    public static var description = IntentDescription("Start a long meeting recording in the background. Shows a Live Activity while recording.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if RecordingIntentBridge.isLiveRecordingActive {
            return .result(dialog: "Already recording")
        }
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .start)
        switch reason {
        case "ok":
            return .result(dialog: "Recording started")
        case "permission":
            try await continueInForeground(
                IntentDialog("Open Shrava to allow microphone access"),
                alwaysConfirm: false
            )
            return .result(dialog: "Open Shrava to allow the microphone")
        case "liveActivity":
            try await continueInForeground(
                IntentDialog("Turn on Live Activities for Shrava in Settings"),
                alwaysConfirm: false
            )
            return .result(dialog: "Enable Live Activities for Shrava")
        case "model":
            try await continueInForeground(
                IntentDialog("Download the Whisper model in Shrava Settings"),
                alwaysConfirm: false
            )
            return .result(dialog: "Download the Whisper model first")
        default:
            return .result(dialog: "Couldn’t start recording")
        }
    }
}

/// Stop the current long recording and transcribe — used by Live Activity Stop and Shortcuts.
@available(iOS 18.0, *)
public struct StopRecordingIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Stop Shrava Recording"
    public static var description = IntentDescription("Stop the current Shrava recording and transcribe it on-device.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard RecordingIntentBridge.isLiveRecordingActive else {
            return .result(dialog: "Not recording")
        }
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .stop)
        if reason == "ok" {
            return .result(dialog: "Recording stopped — transcribing")
        }
        return .result(dialog: "Couldn’t stop recording")
    }
}

/// Toggle recording (Control Center). `value == true` starts, `false` stops.
@available(iOS 18.0, *)
public struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Toggle Shrava Recording"
    public static var description = IntentDescription("Start or stop Shrava long recording from Control Center or Shortcuts.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Recording")
    public var value: Bool

    public init() {}
    public init(value: Bool) {
        self.value = value
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let action: RecordingIntentAction = value ? .start : .stop
        if value, RecordingIntentBridge.isLiveRecordingActive {
            return .result(dialog: "Already recording")
        }
        if !value, !RecordingIntentBridge.isLiveRecordingActive {
            return .result(dialog: "Not recording")
        }
        let reason = await RecordingIntentBridge.dispatchAndWait(action: action)
        switch reason {
        case "ok":
            return .result(dialog: value ? "Recording started" : "Recording stopped")
        case "permission":
            try await continueInForeground(
                IntentDialog("Open Shrava to allow microphone access"),
                alwaysConfirm: false
            )
            return .result(dialog: "Open Shrava to allow the microphone")
        case "liveActivity":
            try await continueInForeground(
                IntentDialog("Turn on Live Activities for Shrava in Settings"),
                alwaysConfirm: false
            )
            return .result(dialog: "Enable Live Activities for Shrava")
        default:
            return .result(dialog: "Couldn’t update recording")
        }
    }
}

#endif
