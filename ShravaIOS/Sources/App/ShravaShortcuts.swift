import AppIntents

@available(iOS 18.0, *)
struct ShravaShortcuts: AppShortcutsProvider {
    /// Toggle first — recommended for Action Button (press once to start, again to stop).
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FlipRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName) recording",
                "Toggle recording in \(.applicationName)",
                "Start or stop \(.applicationName) recording",
                "\(.applicationName) Action Button recording"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
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
            intent: PauseRecordingIntent(),
            phrases: [
                "Pause \(.applicationName) recording"
            ],
            shortTitle: "Pause Recording",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeRecordingIntent(),
            phrases: [
                "Resume \(.applicationName) recording"
            ],
            shortTitle: "Resume Recording",
            systemImageName: "play.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .red }
}
