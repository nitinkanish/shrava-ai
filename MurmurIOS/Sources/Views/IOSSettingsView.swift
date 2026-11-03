import SwiftUI
import MurmurCore

struct IOSSettingsView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var settings = SettingsManager.shared.settings
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                languageSection
                behaviorSection
                syncSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear {
                appState.refreshModelStatus()
            }
        }
    }

    private var modelSection: some View {
        Section {
            LabeledContent("Engine", value: "whisper.cpp (on-device)")
            LabeledContent("Model", value: WhisperModelManager.modelDisplayName)
            LabeledContent("File", value: WhisperModelManager.modelFileName)
            LabeledContent("Size", value: appState.modelManager.formattedSize)
            LabeledContent("Status", value: statusText)

            if isDownloading || isDownloadingStatus {
                ProgressView(value: appState.modelManager.downloadProgress)
                Text("Downloading… \(Int(appState.modelManager.downloadProgress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let downloadError {
                Text(downloadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !appState.modelReady {
                Button(isDownloading ? "Downloading…" : "Download Model") {
                    Task { await downloadModel() }
                }
                .disabled(isDownloading)
            } else {
                Label("Model ready for offline transcription", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }
        } header: {
            Text("On-Device Model")
        } footer: {
            Text("Transcription runs entirely on your device with open-source Whisper. No OpenAI API or API key is used.")
        }
    }

    private var isDownloadingStatus: Bool {
        if case .downloading = appState.modelManager.status { return true }
        return false
    }

    private var statusText: String {
        switch appState.modelManager.status {
        case .ready: return "Ready"
        case .missing: return "Not downloaded"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.language) {
                ForEach(SupportedLanguage.popular, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
                Divider()
                ForEach(SupportedLanguage.others, id: \.self) { language in
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
            Text("About Shrava")
        }
    }

    private func downloadModel() async {
        isDownloading = true
        downloadError = nil
        do {
            try await appState.modelManager.downloadModelWithProgress()
            appState.refreshModelStatus()
        } catch {
            downloadError = error.localizedDescription
        }
        isDownloading = false
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
                    SetupStep(number: 4, text: "Select \"Shrava Keyboard\"")
                    SetupStep(number: 5, text: "Tap on \"Shrava Keyboard\" and enable \"Allow Full Access\"")
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
                Text("The keyboard opens Shrava to record. The Whisper model stays in the main app because keyboard extensions cannot hold a large model in memory.")
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
