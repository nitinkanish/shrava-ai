import SwiftUI
import ShravaCore

struct IOSSettingsView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var settings = SettingsManager.shared.settings
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ShravaTheme.softBackground.opacity(0.45).ignoresSafeArea()
                Form {
                    aboutHero
                    modelSection
                    meetingBriefSection
                    languageSection
                    behaviorSection
                    syncSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .onAppear { appState.refreshModelStatus() }
        }
    }

    private var aboutHero: some View {
        Section {
            VStack(spacing: 12) {
                Image("ShravaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: ShravaTheme.purple.opacity(0.35), radius: 16, y: 8)
                Text("Shrava")
                    .font(.title2.weight(.bold))
                Text(ShravaTheme.tagline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
        }
    }

    private var modelSection: some View {
        Section {
            LabeledContent("Engine", value: "whisper.cpp (on-device)")
            LabeledContent("Status", value: statusText)
            LabeledContent("Active size", value: appState.modelManager.formattedSize)

            ForEach(WhisperModelManager.catalog) { option in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.displayName).font(.body.weight(.semibold))
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(option.formattedExpectedSize)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if appState.modelManager.isInstalled(option) {
                        if appState.modelManager.selectedModelID == option.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Use") {
                                appState.modelManager.select(option)
                                appState.refreshModelStatus()
                            }
                            .buttonStyle(.glass)
                        }
                    } else {
                        Button(isDownloading && appState.modelManager.selectedModelID == option.id ? "…" : "Download") {
                            appState.modelManager.select(option)
                            Task { await downloadModel() }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ShravaTheme.purple)
                        .disabled(isDownloading)
                    }
                }
                .padding(.vertical, 4)
            }

            if isDownloading || isDownloadingStatus {
                ProgressView(value: appState.modelManager.downloadProgress)
                Text("Downloading… \(Int(appState.modelManager.downloadProgress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let downloadError {
                Text(downloadError)
                    .font(.footnote)
                    .foregroundStyle(ShravaTheme.coral)
            }

            if appState.modelReady {
                Label("Selected model ready for offline transcription", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }
        } header: {
            Text("On-Device Model")
        } footer: {
            Text("Prefer Large v3 Turbo for Hindi/English meetings (~547 MB, download once). Smaller models work when storage is tight. Transcription stays on-device.")
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

    private var meetingBriefSection: some View {
        Section {
            NavigationLink {
                IOSAnalysisSettingsView()
            } label: {
                Label("Meeting Brief (Ollama)", systemImage: "sparkles")
            }
            NavigationLink {
                IOSSlackSettingsView()
            } label: {
                Label("Slack", systemImage: "number.square")
            }
        } header: {
            Text("Analysis & integrations")
        } footer: {
            Text("Analyze transcripts into a meeting brief, then optionally send them to a Slack channel.")
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
            Text(settings.language == .auto
                 ? "Auto detects English or Hindi (including Hinglish), then transcribes the whole recording in one pass."
                 : "Always transcribes in \(settings.language.displayName). Choose Auto (English/Hindi) for mixed meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Transcription")
        }
        .onChange(of: settings.language) { _, _ in saveSettings() }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("Auto-cleanup transcriptions", isOn: $settings.autoCleanup)
            Toggle("Enhance transcript (Ollama)", isOn: $settings.enhanceTranscript)
            Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            Toggle("Sound feedback", isOn: $settings.soundFeedback)
        } header: {
            Text("Behavior")
        } footer: {
            Text(OllamaSecrets.hasAPIKey()
                 ? "Enhance uses your Ollama key (gpt-oss:120b-cloud) to polish punctuation and Hinglish after Whisper. Off by default only when no key is saved."
                 : "Enhance transcript needs an Ollama API key under Meeting Brief. It will turn on automatically once a key is saved.")
        }
        .onChange(of: settings.autoCleanup) { _, _ in saveSettings() }
        .onChange(of: settings.enhanceTranscript) { _, _ in saveSettings() }
        .onChange(of: settings.hapticFeedback) { _, _ in saveSettings() }
        .onChange(of: settings.soundFeedback) { _, _ in saveSettings() }
        .onAppear {
            // Default enhance on when an Ollama key exists and user has not explicitly set preference via decode default.
            if OllamaSecrets.hasAPIKey(), settings.enhanceTranscript == false {
                // keep user choice
            }
        }
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
                Text(ShravaCore.version)
                    .foregroundStyle(.secondary)
            }
            NavigationLink("Keyboard Setup") {
                KeyboardSetupView()
            }
        } header: {
            Text("About")
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
                .buttonStyle(.glassProminent)
                .tint(ShravaTheme.purple)
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
                .background(Circle().fill(ShravaTheme.purple))
                .foregroundStyle(.white)

            Text(text)
        }
    }
}

struct IOSAnalysisSettingsView: View {
    @State private var mode: OllamaEndpointMode = AnalysisSettingsStore.load().endpointMode
    @State private var customURL: String = AnalysisSettingsStore.load().customBaseURL
    @State private var model: String = AnalysisSettingsStore.load().model
    @State private var apiKey: String = ""
    @State private var keyPresent = OllamaSecrets.hasAPIKey()
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section("Endpoint") {
                Picker("Provider", selection: $mode) {
                    ForEach(OllamaEndpointMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .onChange(of: mode) { _, _ in persist() }
                if mode == .custom {
                    TextField("Base URL", text: $customURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customURL) { _, _ in persist() }
                }
            }
            Section("Model") {
                TextField("Model name", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model) { _, _ in persist() }
                Text("Default gpt-oss:120b-cloud. Fallback: gpt-oss:120b")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("API key") {
                SecureField(keyPresent ? "•••••••• (replace to update)" : "Paste API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save to Keychain") { saveKey() }
                    .buttonStyle(.glassProminent)
                    .tint(ShravaTheme.purple)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keyPresent {
                    Button("Remove key", role: .destructive) {
                        OllamaSecrets.deleteAPIKey()
                        keyPresent = false
                        apiKey = ""
                    }
                }
                Text(keyPresent ? "Key stored in Keychain" : "No key stored")
                    .font(.caption)
                    .foregroundStyle(keyPresent ? .green : .secondary)
            }
            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    if testing { ProgressView() } else { Text("Test connection") }
                }
                .buttonStyle(.glass)
                .disabled(testing)
                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testOK ? .green : ShravaTheme.coral)
                }
            }
        }
        .navigationTitle("Meeting Brief")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func persist() {
        var s = AnalysisSettingsStore.load()
        s.endpointMode = mode
        s.customBaseURL = customURL
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        s.model = m.isEmpty ? AnalysisSettings.default.model : m
        AnalysisSettingsStore.save(s)
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OllamaSecrets.saveAPIKey(trimmed)
            keyPresent = true
            apiKey = ""
            testOK = true
            testMessage = "API key saved to Keychain."
        } catch {
            testOK = false
            testMessage = error.localizedDescription
        }
    }

    private func runTest() async {
        persist()
        testing = true
        defer { testing = false }
        do {
            let reply = try await OllamaClient.shared.testConnection()
            testOK = true
            testMessage = "Connected: \(String(reply.prefix(80)))"
        } catch {
            testOK = false
            testMessage = error.localizedDescription
        }
    }
}
