import SwiftUI
import ShravaCore

@main
struct ShravaIOSApp: App {
    init() {
        LegacyMigration.runAll()
        // Cold-start via LiveActivityIntent can run perform() before WindowGroup
        // evaluates @StateObject — force singleton (and intent executor) now.
        _ = IOSAppState.shared
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
        case "live", "recording":
            // Live Activity / Dynamic Island tap — show live timer + Stop, or History after stop.
            if appState.isRecording {
                appState.openRecordTabForLiveActivity()
            } else if appState.pendingOpenHistoryID != nil || appState.isProcessing {
                if let id = appState.pendingOpenHistoryID {
                    appState.openHistoryItem(id)
                } else {
                    appState.currentTab = .history
                }
            } else {
                appState.openRecordTabForLiveActivity()
            }
        case "debug":
            // shrava://debug/* — DEBUG builds only (disabled in Release).
            #if DEBUG
            let path = url.pathComponents.dropFirst().first?.lowercased() ?? "long"
            appState.debugStart(path: path)
            #endif
        case "history":
            appState.currentTab = .history
            if let idStr = url.pathComponents.dropFirst().first, let id = UUID(uuidString: idStr) {
                appState.openHistoryItem(id)
            } else if let pending = appState.pendingOpenHistoryID {
                appState.openHistoryItem(pending)
            }
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
