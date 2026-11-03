import SwiftUI
import MurmurCore

struct IOSSettingsView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var settings = SettingsManager.shared.settings
    @State private var apiKey = ""
    @State private var showingAPIKey = false
    @State private var showingSaveConfirmation = false
    
    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                
                languageSection
                
                behaviorSection
                
                syncSection
                
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            if let key = try? KeychainManager.shared.loadOpenAIAPIKey() {
                apiKey = key
            }
        }
    }
    
    private var apiKeySection: some View {
        Section {
            HStack {
                if showingAPIKey {
                    TextField("API Key", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("API Key", text: $apiKey)
                }
                
                Button(action: { showingAPIKey.toggle() }) {
                    Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Button("Save API Key") {
                saveAPIKey()
            }
            .disabled(apiKey.isEmpty)
            
            Link("Get API Key from OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
        } header: {
            Text("OpenAI API")
        } footer: {
            Text("Your API key is stored securely in the iOS Keychain.")
        }
        .alert("API Key Saved", isPresented: $showingSaveConfirmation) {
            Button("OK", role: .cancel) {}
        }
    }
    
    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.language) {
                ForEach(SupportedLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } header: {
            Text("Transcription")
        }
        .onChange(of: settings.language) { _, _ in
            saveSettings()
        }
    }
    
    private var behaviorSection: some View {
        Section {
            Toggle("Auto-cleanup transcriptions", isOn: $settings.autoCleanup)
            Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            Toggle("Sound feedback", isOn: $settings.soundFeedback)
        } header: {
            Text("Behavior")
        }
        .onChange(of: settings.autoCleanup) { _, _ in saveSettings() }
        .onChange(of: settings.hapticFeedback) { _, _ in saveSettings() }
        .onChange(of: settings.soundFeedback) { _, _ in saveSettings() }
    }
    
    private var syncSection: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
        } header: {
            Text("Sync")
        } footer: {
            Text("Sync your dictionary and recent history across your Mac and iOS devices.")
        }
        .onChange(of: settings.iCloudSyncEnabled) { _, newValue in
            saveSettings()
            CloudSyncManager.shared.setEnabled(newValue)
        }
    }
    
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(MurmurCore.version)
                    .foregroundStyle(.secondary)
            }
            
            NavigationLink("Keyboard Setup") {
                KeyboardSetupView()
            }
        } header: {
            Text("About")
        }
    }
    
    private func saveAPIKey() {
        do {
            try KeychainManager.shared.saveOpenAIAPIKey(apiKey)
            appState.refreshAPIKey()
            showingSaveConfirmation = true
        } catch {
            print("Failed to save API key: \(error)")
        }
    }
    
    private func saveSettings() {
        SettingsManager.shared.settings = settings
    }
}

struct KeyboardSetupView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    SetupStep(number: 1, text: "Open Settings app")
                    SetupStep(number: 2, text: "Go to General → Keyboard → Keyboards")
                    SetupStep(number: 3, text: "Tap \"Add New Keyboard...\"")
                    SetupStep(number: 4, text: "Select \"Murmur Keyboard\"")
                    SetupStep(number: 5, text: "Tap on \"Murmur Keyboard\" and enable \"Allow Full Access\"")
                }
                .padding(.vertical, 8)
            } header: {
                Text("Setup Instructions")
            }
            
            Section {
                Button("Open Keyboard Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            
            Section {
                Text("Full Access is required for the keyboard to communicate with the main app for voice recording.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Why Full Access?")
            }
        }
        .navigationTitle("Keyboard Setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupStep: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.blue))
                .foregroundStyle(.white)
            
            Text(text)
        }
    }
}
