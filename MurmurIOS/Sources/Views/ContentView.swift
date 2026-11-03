import SwiftUI
import MurmurCore

struct ContentView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var showingOnboarding = false
    
    var body: some View {
        TabView(selection: $appState.currentTab) {
            RecordingView()
                .environmentObject(appState)
                .tabItem {
                    Label("Record", systemImage: "waveform.circle")
                }
                .tag(IOSAppState.Tab.record)
            
            IOSHistoryView()
                .environmentObject(appState)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(IOSAppState.Tab.history)
            
            IOSDictionaryView()
                .environmentObject(appState)
                .tabItem {
                    Label("Dictionary", systemImage: "character.book.closed")
                }
                .tag(IOSAppState.Tab.dictionary)
            
            IOSSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(IOSAppState.Tab.settings)
        }
        .onAppear {
            checkOnboarding()
        }
        .sheet(isPresented: $showingOnboarding) {
            IOSOnboardingView(isPresented: $showingOnboarding)
                .environmentObject(appState)
        }
    }
    
    private func checkOnboarding() {
        let hasAPIKey = KeychainManager.shared.hasOpenAIAPIKey
        let hasMicPermission = appState.hasMicrophonePermission
        
        if !hasAPIKey || !hasMicPermission {
            showingOnboarding = true
        }
    }
}
