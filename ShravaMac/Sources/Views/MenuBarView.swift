import SwiftUI
import ShravaCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
            
            statusSection
            
            Divider()
            
            languageSection
            
            Divider()
            
            actionSection
            
            Divider()
            
            footerSection
        }
        .frame(width: 280)
    }
    
    @State private var language = SettingsManager.shared.settings.language

    private var languageSection: some View {
        HStack {
            Image(systemName: "globe").foregroundStyle(.secondary)
            LanguagePicker(selection: $language)
                .labelsHidden()
                .pickerStyle(.menu)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: language) { _, newValue in
            SettingsManager.shared.settings.language = newValue
        }
        .onAppear { language = SettingsManager.shared.settings.language }
    }

    private var headerSection: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 24, height: 24)
            
            Text("Shrava")
                .font(.headline)
            
            Spacer()
            
            if appState.isRecording {
                RecordingIndicator()
            } else if appState.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding()
    }
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = appState.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if !appState.lastTranscription.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last transcription:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.lastTranscription)
                        .font(.caption)
                        .lineLimit(3)
                }
            } else {
                Text("Hold \(currentHotkeyDescription) to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var actionSection: some View {
        VStack(spacing: 4) {
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            Button(action: {
                HistoryWindowController.shared.showWindow()
            }) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            Button(action: {
                DictionaryWindowController.shared.showWindow()
            }) {
                HStack {
                    Image(systemName: "character.book.closed")
                    Text("Dictionary")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }
    
    private var footerSection: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "power")
                Text("Quit Shrava")
                Spacer()
                Text("⌘Q")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding()
    }
    
    private var currentHotkeyDescription: String {
        HotkeyManager.hotkeyDescription(
            keyCode: SettingsManager.shared.settings.hotkeyKeyCode,
            modifiers: SettingsManager.shared.settings.hotkeyModifiers
        )
    }
}

struct RecordingIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .scaleEffect(isAnimating ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}
