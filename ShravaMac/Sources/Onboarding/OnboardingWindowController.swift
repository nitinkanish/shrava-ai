import SwiftUI
import AppKit
import ShravaCore

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private init() {}

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = OnboardingView(onComplete: { [weak self] in
            self?.window?.close()
            self?.window = nil
        })

        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Welcome to Shrava"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 560)
        window.setContentSize(NSSize(width: 620, height: 560))

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    @State private var currentStep: Int
    @State private var hasMicPermission = PermissionManager.shared.hasMicrophonePermission
    @State private var hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
    private let poll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    let onComplete: () -> Void
    private let stepCount = 5

    init(initialStep: Int = 0, onComplete: @escaping () -> Void) {
        self._currentStep = State(initialValue: initialStep)
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: modelStep
                case 2: microphoneStep
                case 3: accessibilityStep
                default: completeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            navigationBar
        }
        .frame(minWidth: 620, minHeight: 560)
        .frame(width: 620, height: 560)
        .onReceive(poll) { _ in
            hasMicPermission = PermissionManager.shared.hasMicrophonePermission
            hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 16) {
            if currentStep > 0 {
                Button("Back") { currentStep -= 1 }
                    .keyboardShortcut(.cancelAction)
            } else {
                Color.clear.frame(width: 60, height: 1)
            }

            Spacer()

            HStack(spacing: 8) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == currentStep ? 18 : 8, height: 8)
                }
            }

            Spacer()

            if currentStep < stepCount - 1 {
                Button("Next") { currentStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Get Started") { onComplete() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minHeight: 56)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            Text("Welcome to Shrava")
                .font(.system(size: 28, weight: .bold))
            Text("Every Conversation, Captured")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Private voice dictation, powered by Whisper on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "mic.fill", text: "Hold Fn to talk, double-tap for hands-free")
                FeatureRow(icon: "wand.and.stars", text: "Removes filler words and adds punctuation")
                FeatureRow(icon: "text.cursor", text: "Types the text wherever your cursor is")
                FeatureRow(icon: "sparkles", text: "Analyze meetings into briefs and action items")
            }
            .padding(.top, 8)
            .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var modelStep: some View {
        let modelReady = LocalWhisper.shared.modelURL != nil && LocalWhisper.shared.binaryPath != nil
        return VStack(spacing: 18) {
            stepIcon("cpu", color: .orange)
            Text("On-device Whisper")
                .font(.system(size: 26, weight: .bold))
            Text("Shrava transcribes with the open-source Whisper model running locally. No cloud account is required for dictation, and your voice stays on this Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            statusChip(
                modelReady ? "Ready" : "Model missing",
                ok: modelReady,
                detail: modelReady
                    ? (LocalWhisper.shared.modelURL?.lastPathComponent ?? "Model found")
                    : "Place a ggml model in Application Support → Shrava → models"
            )

            Text("Meeting Brief analysis can optionally use Ollama (Cloud or local) from Settings → Meeting Brief.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            Spacer(minLength: 0)
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 18) {
            stepIcon(hasMicPermission ? "mic.fill" : "mic.slash.fill",
                     color: hasMicPermission ? .green : .red)
            Text("Microphone Access")
                .font(.system(size: 26, weight: .bold))
            Text("Shrava needs the microphone to capture dictation and meeting recordings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            if hasMicPermission {
                statusChip("Granted", ok: true, detail: "Microphone is ready")
            } else {
                Button("Grant Microphone Access") {
                    Task {
                        hasMicPermission = await PermissionManager.shared.requestMicrophonePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 18) {
            stepIcon(hasAccessibilityPermission ? "hand.raised.fill" : "hand.raised.slash.fill",
                     color: hasAccessibilityPermission ? .green : .orange)
            Text("Accessibility Access")
                .font(.system(size: 26, weight: .bold))
            Text("Needed to detect the Fn hotkey and type transcribed text into other apps.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            if hasAccessibilityPermission {
                statusChip("Granted", ok: true, detail: "Accessibility is enabled for Shrava")
            } else {
                VStack(spacing: 12) {
                    Button("Open System Settings") {
                        PermissionManager.shared.requestAccessibilityPermission()
                        PermissionManager.shared.openAccessibilityPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Find Shrava in Privacy & Security → Accessibility, enable it, then return here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)

                    Button("Check Again") {
                        hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var completeStep: some View {
        VStack(spacing: 18) {
            stepIcon("checkmark.circle.fill", color: .green, size: 72)
            Text("You're all set")
                .font(.system(size: 28, weight: .bold))
            Text("Hold Fn to dictate. Double-tap Fn for hands-free meetings, then tap Fn again to stop. Open History afterward and tap Analyze for a Meeting Brief.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            VStack(alignment: .leading, spacing: 8) {
                tipRow("Menu bar icon for History, Dictionary, and Settings")
                tipRow("Settings → Meeting Brief to connect Ollama")
                tipRow("Add custom words in Dictionary for names and jargon")
            }
            .padding(.top, 4)
            .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Chrome

    private func stepIcon(_ name: String, color: Color, size: CGFloat = 56) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size + 24, height: size + 24)
            .background(Circle().fill(color.opacity(0.12)))
    }

    private func statusChip(_ title: String, ok: Bool, detail: String) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(ok ? .green : .orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.12)))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
