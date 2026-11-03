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
            }
        }
    }
    
    private func handleURLScheme(_ url: URL) {
        guard url.scheme == "shrava" else { return }
        
        if url.host == "record" {
            appState.startRecordingFromKeyboard()
        }
    }
}
