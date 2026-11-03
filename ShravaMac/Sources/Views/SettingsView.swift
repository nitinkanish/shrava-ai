import SwiftUI
import ShravaCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }.tag(0)
            IndicatorSettingsView().tabItem { Label("Indicator", systemImage: "waveform.circle") }.tag(1)
            APISettingsView().tabItem { Label("Model", systemImage: "cpu") }.tag(2)
            HotkeySettingsView().tabItem { Label("Hotkey", systemImage: "keyboard") }.tag(3)
            PermissionsSettingsView().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(4)
            DataSettingsView().environmentObject(appState).tabItem { Label("Data", systemImage: "chart.bar") }.tag(5)
            SyncSettingsView().tabItem { Label("Sync", systemImage: "icloud") }.tag(6)
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }.tag(7)
        }
        .frame(width: 620, height: 460)
        .padding()
    }
}

struct GeneralSettingsView: View {
    @State private var settings = SettingsManager.shared.settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Language") {
                LanguagePicker(selection: $settings.language)
                Text(settings.language == .auto
                     ? "Shrava detects the language you speak each time. Pick a fixed language if words come out in the wrong one."
                     : "Shrava always transcribes in \(settings.language.displayName). Choose Auto-detect to switch languages freely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Auto-cleanup (remove um, uh, repeats; fix capitals)", isOn: $settings.autoCleanup)
                Toggle("Show original text in History", isOn: $settings.showOriginalText)
            }
            Section("Behaviour") {
                Toggle("Sound feedback when recording starts and stops", isOn: $settings.soundFeedback)
                Toggle("Insert text with Accessibility (recommended)", isOn: $settings.useAccessibilityInsertion)
                Text("When off, Shrava pastes through the clipboard instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch Shrava at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { NSLog("Shrava: login item \(error)") }
                    }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, newValue in SettingsManager.shared.settings = newValue }
    }
}

struct IndicatorSettingsView: View {
    @AppStorage("showIndicator") private var show = true
    @AppStorage("indicatorPosition") private var position = IndicatorPosition.bottomCenter.rawValue
    @AppStorage("indicatorAccent") private var accent = IndicatorAccent.aurora.rawValue

    var body: some View {
        Form {
            Section("Floating indicator") {
                Toggle("Show the floating indicator while recording", isOn: $show)
                Text("Drag the indicator anywhere on screen while it's showing. Shrava remembers the spot.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to default position") { UserDefaults.standard.removeObject(forKey: "indicatorOrigin") }
                Picker("Default position", selection: $position) {
                    ForEach(IndicatorPosition.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: position) { _, _ in UserDefaults.standard.removeObject(forKey: "indicatorOrigin") }
                Picker("Colour theme", selection: $accent) {
                    ForEach(IndicatorAccent.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("Preview") {
                HStack(spacing: 3) {
                    let c = (IndicatorAccent(rawValue: accent) ?? .aurora).colors
                    Circle().fill(AngularGradient(colors: c + [c[0]], center: .center)).frame(width: 16, height: 16)
                        .padding(.trailing, 8)
                    ForEach(0..<22, id: \.self) { i in
                        Capsule().fill(LinearGradient(colors: c, startPoint: .bottom, endPoint: .top))
                            .frame(width: 3, height: 6 + abs(sin(Double(i) * 0.7)) * 22)
                    }
                    Spacer().frame(width: 10)
                    Text("0:04").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .frame(maxWidth: .infinity)
                Text("The bars follow your voice live. While Whisper works, the pill shows \"Transcribing\" with an on-device lock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct APISettingsView: View {
    @AppStorage("whisperThreads") private var threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    @State private var testResult: String?
    @State private var testing = false

    private var model: URL? { LocalWhisper.shared.modelURL }
    private var modelSize: String {
        guard let m = model, let n = (try? FileManager.default.attributesOfItem(atPath: m.path))?[.size] as? Int64 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    var body: some View {
        Form {
            Section("Transcription engine") {
                LabeledContent("Engine", value: "Whisper (open source, on-device)")
                LabeledContent("Model", value: model?.lastPathComponent ?? "No model found")
                LabeledContent("Model size", value: modelSize)
                LabeledContent("Runtime", value: LocalWhisper.shared.binaryPath ?? "whisper-cli not installed")
                LabeledContent("Acceleration", value: "Apple Silicon GPU (Metal)")
                LabeledContent("Status") {
                    Label(model != nil && LocalWhisper.shared.binaryPath != nil ? "Ready" : "Not ready",
                          systemImage: model != nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(model != nil ? .green : .red)
                }
            }
            Section("Performance") {
                Stepper("CPU threads: \(threads)", value: $threads, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                Text("More threads can be faster but use more battery. Your Mac has \(ProcessInfo.processInfo.activeProcessorCount) cores.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label("Audio never leaves this Mac. No account or API key is needed.", systemImage: "lock.fill")
                    .font(.callout)
            }
            Section {
                HStack {
                    Button("Open models folder") {
                        try? FileManager.default.createDirectory(at: LocalWhisper.modelsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LocalWhisper.modelsDirectory)
                    }
                    Link("Whisper on GitHub", destination: URL(string: "https://github.com/openai/whisper")!)
                }
                Text("Drop another ggml model there (for example ggml-small.bin) to switch. large-v3-turbo is preferred when present.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsSettingsView: View {
    @State private var mic = PermissionManager.shared.hasMicrophonePermission
    @State private var ax = PermissionManager.shared.hasAccessibilityPermission
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Required permissions") {
                row("Microphone", "To hear your voice while you hold the hotkey.", mic) {
                    PermissionManager.shared.openMicrophonePreferences()
                }
                row("Accessibility", "To detect the Fn key and type text into any app.", ax) {
                    PermissionManager.shared.openAccessibilityPreferences()
                }
            }
            Section {
                Text("If Fn stops working after an update, switch Shrava off and on again in Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in
            mic = PermissionManager.shared.hasMicrophonePermission
            ax = PermissionManager.shared.hasAccessibilityPermission
        }
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(ok ? "Granted" : "Open Settings", action: open).disabled(ok)
        }
    }
}

struct DataSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [HistoryEntry] = []
    @State private var confirmClear = false

    private var words: Int { entries.reduce(0) { $0 + $1.cleanedText.split(whereSeparator: \.isWhitespace).count } }
    private var seconds: Double { entries.reduce(0) { $0 + $1.durationSeconds } }
    private var wpm: Int { seconds > 0 ? Int(Double(words) / (seconds / 60)) : 0 }
    private var minutesSaved: Int { max(0, Int(Double(words) / 40.0 - seconds / 60)) } // vs ~40 wpm typing

    var body: some View {
        Form {
            Section("Your dictation") {
                HStack(spacing: 12) {
                    stat("\(words)", "words")
                    stat("\(entries.count)", "recordings")
                    stat("\(wpm)", "avg wpm")
                    stat("\(minutesSaved)m", "saved vs typing")
                }
                Text("Time saved assumes an average typing speed of 40 words per minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("History file", value: ShravaCore.historyStorageURL()?.path ?? "-")
                HStack {
                    Button("Show in Finder") { if let u = ShravaCore.historyStorageURL() { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    Spacer()
                    Button("Clear all history", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .task { entries = await appState.historyManager.getAll() }
        .confirmationDialog("Delete all \(entries.count) recordings from History?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) {
                Task {
                    await appState.historyManager.clear()
                    entries = []
                    NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
    }
}

struct AboutSettingsView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Shrava").font(.title).bold()
            Text("Every Conversation, Captured").font(.headline).foregroundStyle(.secondary)
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Hold Fn to talk. Double-tap Fn for hands-free, tap again to stop.")
                .font(.callout).multilineTextAlignment(.center).padding(.top, 6)
            Text("Speech recognition by the open-source Whisper model, running on-device with whisper.cpp.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HotkeySettingsView: View {
    @State private var settings = SettingsManager.shared.settings
    @State private var isRecordingHotkey = false
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Hold-to-talk hotkey:")
                    
                    Spacer()
                    
                    if isRecordingHotkey {
                        Text("Press a key...")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(currentHotkeyDescription)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    Button(isRecordingHotkey ? "Cancel" : "Change") {
                        isRecordingHotkey.toggle()
                    }
                }
                
                Text("Default: Fn key. Alternative: Control+Option")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                Button("Reset to Default (Fn)") {
                    settings.hotkeyKeyCode = 63
                    settings.hotkeyModifiers = 0
                    SettingsManager.shared.settings = settings
                    HotkeyManager.shared.setHotkey(keyCode: 63, modifiers: [])
                }
                
                Button("Use Control+Option") {
                    settings.hotkeyKeyCode = 0
                    settings.hotkeyModifiers = UInt(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
                    SettingsManager.shared.settings = settings
                    HotkeyManager.shared.setHotkey(
                        keyCode: 0,
                        modifiers: [.maskControl, .maskAlternate]
                    )
                }
            }
        }
    }
    
    private var currentHotkeyDescription: String {
        HotkeyManager.hotkeyDescription(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
    }
}

struct SyncSettingsView: View {
    @State private var settings = SettingsManager.shared.settings
    
    var body: some View {
        Form {
            Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
            
            Text("Sync your dictionary and recent history across your Mac and iOS devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.iCloudSyncEnabled) { oldValue, newValue in
            SettingsManager.shared.settings = settings
            CloudSyncManager.shared.setEnabled(newValue)
        }
    }
}


struct LanguagePicker: View {
    @Binding var selection: SupportedLanguage
    var body: some View {
        Picker("Dictation language", selection: $selection) {
            ForEach(SupportedLanguage.popular, id: \.self) { Text($0.displayName).tag($0) }
            Divider()
            ForEach(SupportedLanguage.others, id: \.self) { Text($0.displayName).tag($0) }
        }
    }
}
