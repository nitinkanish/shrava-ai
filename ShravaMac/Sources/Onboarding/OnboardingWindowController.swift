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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.title = "Welcome to Shrava"
        window.center()
        window.isReleasedWhenClosed = false
        
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var hasMicPermission = PermissionManager.shared.hasMicrophonePermission
    @State private var hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
    
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            
            Divider()
            
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    apiKeyStep
                case 2:
                    microphoneStep
                case 3:
                    accessibilityStep
                case 4:
                    completeStep
                default:
                    welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            navigationButtons
        }
        .frame(width: 500, height: 450)
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<5) { index in
                Circle()
                    .fill(index <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding()
    }
    
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 110, height: 110)
            
            Text("Welcome to Shrava")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Every Conversation, Captured")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            Text("Voice dictation powered by AI. Speak naturally and get clean, polished text.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "mic.fill", text: "Hold a hotkey to record")
                FeatureRow(icon: "wand.and.stars", text: "AI removes filler words and adds punctuation")
                FeatureRow(icon: "text.cursor", text: "Text is inserted where you're typing")
            }
            .padding(.top, 20)
        }
        .padding()
    }
    
    private var apiKeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Private, on-device Whisper")
                .font(.title).fontWeight(.bold)
            Text("Shrava transcribes with the open-source Whisper model running locally on your Mac. No account, no API key, and your voice never leaves this computer.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Text(LocalWhisper.shared.modelURL != nil ? "Model ready ✓" : "Model not found in ~/Library/Application Support/Shrava/models")
                .font(.caption).foregroundStyle(LocalWhisper.shared.modelURL != nil ? .green : .red)
        }
        .padding()
    }
    
    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: hasMicPermission ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 60))
                .foregroundStyle(hasMicPermission ? .green : .red)
            
            Text("Microphone Access")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Shrava needs access to your microphone to transcribe your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if hasMicPermission {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Microphone Access") {
                    Task {
                        hasMicPermission = await PermissionManager.shared.requestMicrophonePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            hasMicPermission = PermissionManager.shared.hasMicrophonePermission
        }
    }
    
    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: hasAccessibilityPermission ? "hand.raised.fill" : "hand.raised.slash.fill")
                .font(.system(size: 60))
                .foregroundStyle(hasAccessibilityPermission ? .green : .orange)
            
            Text("Accessibility Access")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Shrava uses Accessibility to insert text directly into applications and register global hotkeys.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if hasAccessibilityPermission {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 12) {
                    Button("Open System Preferences") {
                        PermissionManager.shared.openAccessibilityPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Text("Add Shrava to the list and enable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button("Check Again") {
                        hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .onAppear {
            hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
        }
    }
    
    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            
            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Hold the Fn key to start recording. Release to transcribe and insert text.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick tips:")
                    .font(.headline)
                
                Text("• Access Shrava from the menu bar")
                Text("• Change the hotkey in Settings")
                Text("• Add custom words in Dictionary")
            }
            .padding(.top, 20)
            .padding(.horizontal, 40)
        }
        .padding()
    }
    
    private var navigationButtons: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    currentStep -= 1
                }
            }
            
            Spacer()
            
            if currentStep < 4 {
                Button("Next") {
                    currentStep += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            
            Text(text)
                .font(.body)
        }
    }
}
