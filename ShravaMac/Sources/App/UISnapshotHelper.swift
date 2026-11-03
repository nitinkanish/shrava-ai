import SwiftUI
import AppKit
import ShravaCore

enum UISnapshotHelper {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--capture-ui-screens") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do {
                let dir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Projects/Shrava/dist/screens", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                try render(
                    OnboardingView(initialStep: 0, onComplete: {}),
                    size: CGSize(width: 620, height: 560),
                    to: dir.appendingPathComponent("onboarding-welcome.png")
                )
                try render(
                    OnboardingView(initialStep: 1, onComplete: {}),
                    size: CGSize(width: 620, height: 560),
                    to: dir.appendingPathComponent("onboarding-model.png")
                )
                try render(
                    HotkeySettingsView()
                        .formStyle(.grouped)
                        .frame(width: 580, height: 420)
                        .padding(),
                    size: CGSize(width: 620, height: 500),
                    to: dir.appendingPathComponent("settings-hotkey.png")
                )
                fputs("UISnapshotHelper: done → \(dir.path)\n", stderr)
            } catch {
                fputs("UISnapshotHelper failed: \(error)\n", stderr)
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        // Attach to an offscreen window so SwiftUI lays out properly.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "UISnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "bitmapImageRep nil"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UISnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "png nil"])
        }
        try data.write(to: url)
        window.close()
        fputs("UISnapshotHelper: \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)\n", stderr)
    }
}
