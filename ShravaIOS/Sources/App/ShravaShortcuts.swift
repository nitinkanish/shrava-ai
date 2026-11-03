import AppIntents

@available(iOS 18.0, *)
struct ShravaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start \(.applicationName) recording",
                "Start recording with \(.applicationName)",
                "Record a meeting with \(.applicationName)",
                "Start long recording in \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop \(.applicationName) recording",
                "Stop recording with \(.applicationName)",
                "End \(.applicationName) recording"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName) recording",
                "Toggle recording in \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
    }
}
