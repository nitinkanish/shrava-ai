import SwiftUI
import MurmurCore

@main
struct MurmurMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(appState.isRecording ? 1 : 0.9)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var floatingIndicator: FloatingIndicatorController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        checkOnboardingNeeded()
        setupHotkey()
        floatingIndicator = FloatingIndicatorController()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateChanged),
            name: .recordingStateChanged,
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.unregister()
    }
    
    private func checkOnboardingNeeded() {
        let hasAPIKey = true
        let hasMicPermission = PermissionManager.shared.hasMicrophonePermission
        let hasAccessibilityPermission = PermissionManager.shared.hasAccessibilityPermission
        
        if !hasAPIKey || !hasMicPermission || !hasAccessibilityPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindowController.shared.showWindow()
            }
        }
    }
    
    private func setupHotkey() {
        hotkeyManager = HotkeyManager.shared
        hotkeyManager?.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                await AppState.shared.startRecording()
                self?.floatingIndicator?.show()
            }
        }
        hotkeyManager?.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                self?.floatingIndicator?.hide()
                await AppState.shared.stopRecordingAndTranscribe()
            }
        }
        hotkeyManager?.onHotkeyCancel = { [weak self] in
            Task { @MainActor in
                self?.floatingIndicator?.hide()
                await AppState.shared.cancelRecording()
            }
        }
        hotkeyManager?.register()
    }
    
    @MainActor @objc private func recordingStateChanged(_ notification: Notification) {
        if let isRecording = notification.userInfo?["isRecording"] as? Bool {
            if isRecording {
                floatingIndicator?.show()
            } else {
                floatingIndicator?.hide()
            }
        }
    }
}

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("com.murmurapp.recordingStateChanged")
}
