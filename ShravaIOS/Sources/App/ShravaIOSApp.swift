import SwiftUI
import ShravaCore

@main
struct ShravaIOSApp: App {
    init() {
        LegacyMigration.runAll()
    }

    @StateObject private var appState = IOSAppState.shared
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    handleURLScheme(url)
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                appState.checkForPendingTranscription()
                appState.applyScreenshotTabIfNeeded()
            }
        }
    }
    
    private func handleURLScheme(_ url: URL) {
        guard url.scheme == "shrava" else { return }

        switch url.host {
        case "record":
            appState.startRecordingFromKeyboard()
        case "history":
            appState.currentTab = .history
        case "dictionary":
            appState.currentTab = .dictionary
        case "settings":
            appState.currentTab = .settings
        case "tab":
            let name = url.pathComponents.dropFirst().first?.lowercased()
            switch name {
            case "record": appState.currentTab = .record
            case "history": appState.currentTab = .history
            case "dictionary": appState.currentTab = .dictionary
            case "settings": appState.currentTab = .settings
            default: break
            }
        default:
            break
        }
    }
}
