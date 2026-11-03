import Foundation
import AppIntents
import ActivityKit

#if os(iOS)

// MARK: - Bridge (intents ↔ app process via LiveActivityIntent routing)

enum RecordingIntentAction: String {
    case start
    case stop
    case toggle
    case pause
    case resume
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

/// App process registers a direct handler so LiveActivityIntent does not depend on
/// NotificationCenter race with observer registration.
enum RecordingIntentExecutor {
    /// Returns settle reason ("ok", "permission", …). Set from IOSAppState.init.
    static var handle: (@MainActor (RecordingIntentAction) async -> String)?
}

/// Waits inside `perform()` so AudioRecordingIntent’s mic grant stays open until recording actually starts.
enum RecordingIntentBridge {
    static let timeout: TimeInterval = 15

    @discardableResult
    static func dispatchAndWait(action: RecordingIntentAction) async -> String {
        if let handle = RecordingIntentExecutor.handle {
            return await handle(action)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
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
        // Even if ActivityKit shows nothing, still ask the app to stop / recover orphans.
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .stop)
        if reason == "ok" {
            return .result(dialog: "Recording stopped — transcribing")
        }
        if reason == "notRecording" {
            return .result(dialog: "Not recording")
        }
        return .result(dialog: "Couldn’t stop recording")
    }
}

/// Pause the current long recording (Live Activity / Shortcuts).
@available(iOS 18.0, *)
public struct PauseRecordingIntent: AppIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Pause Shrava Recording"
    public static var description = IntentDescription("Pause the current Shrava meeting recording.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .pause)
        return .result(dialog: reason == "ok" ? "Paused" : "Couldn’t pause")
    }
}

/// Resume a paused long recording (Live Activity / Shortcuts).
@available(iOS 18.0, *)
public struct ResumeRecordingIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Resume Shrava Recording"
    public static var description = IntentDescription("Resume a paused Shrava meeting recording.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .resume)
        return .result(dialog: reason == "ok" ? "Resumed" : "Couldn’t resume")
    }
}

/// Flip recording on/off — recommended Action Button / Siri shortcut.
@available(iOS 18.0, *)
public struct FlipRecordingIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Toggle Shrava Recording"
    public static var description = IntentDescription("Start recording if idle, or stop and transcribe if already recording. Best for Action Button.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let reason = await RecordingIntentBridge.dispatchAndWait(action: .toggle)
        switch reason {
        case "ok", "started":
            return .result(dialog: "Recording started")
        case "stopped":
            return .result(dialog: "Recording stopped — transcribing")
        case "permission":
            try await continueInForeground(
                IntentDialog("Open Shrava to allow microphone access"),
                alwaysConfirm: false
            )
            return .result(dialog: "Open Shrava to allow the microphone")
        case "model":
            try await continueInForeground(
                IntentDialog("Download the Whisper model in Shrava Settings"),
                alwaysConfirm: false
            )
            return .result(dialog: "Download the Whisper model first")
        default:
            return .result(dialog: "Couldn’t toggle recording")
        }
    }
}

/// Toggle recording (Control Center). `value == true` starts, `false` stops.
@available(iOS 18.0, *)
public struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Set Shrava Recording"
    public static var description = IntentDescription("Start or stop Shrava long recording from Control Center.")

    public static var openAppWhenRun: Bool { false }
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Recording")
    public var value: Bool

    public init() {
        self.value = false
    }
    public init(value: Bool) {
        self.value = value
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let action: RecordingIntentAction = value ? .start : .stop
        if value, RecordingIntentBridge.isLiveRecordingActive {
            return .result(dialog: "Already recording")
        }
        let reason = await RecordingIntentBridge.dispatchAndWait(action: action)
        switch reason {
        case "ok":
            return .result(dialog: value ? "Recording started" : "Recording stopped")
        case "notRecording":
            return .result(dialog: "Not recording")
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
