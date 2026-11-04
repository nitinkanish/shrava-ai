import SwiftUI
import ShravaCore

struct IOSOnboardingView: View {
    @EnvironmentObject var appState: IOSAppState
    @Binding var isPresented: Bool

    @State private var currentStep = 0
    @State private var hasMicPermission = false
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $currentStep) {
                    welcomeStep.tag(0)
                    modelStep.tag(1)
                    microphoneStep.tag(2)
                    keyboardStep.tag(3)
                    completeStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                navigationButtons
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            hasMicPermission = appState.hasMicrophonePermission
            appState.refreshModelStatus()
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.blue)

            Text("Welcome to Shrava")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Every Conversation, Captured")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("On-device voice dictation with open-source Whisper.\nNo cloud API. No API key.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: appState.modelReady ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(appState.modelReady ? .green : .orange)

            Text("On-Device Whisper Model")
                .font(.title)
                .fontWeight(.bold)

            Text("Shrava downloads a multilingual Whisper model on first use (Large v3 Turbo ~547 MB recommended for Hindi/English; smaller options in Settings), then transcribes entirely on your iPhone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                labeledRow("Engine", "whisper.cpp (Metal)")
                labeledRow("Model", WhisperModelManager.modelDisplayName)
                labeledRow("File", WhisperModelManager.modelFileName)
                labeledRow("Size", appState.modelManager.formattedSize)
                labeledRow("Status", statusText)
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)

            if isDownloading || isDownloadingStatus {
                ProgressView(value: appState.modelManager.downloadProgress)
                    .padding(.horizontal, 32)
                Text("Downloading… \(Int(appState.modelManager.downloadProgress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let downloadError {
                Text(downloadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if !appState.modelReady {
                Button(isDownloading ? "Downloading…" : "Download Model") {
                    Task { await downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            } else {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding()
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

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var microphoneStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: hasMicPermission ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 80))
                .foregroundStyle(hasMicPermission ? .green : .red)

            Text("Microphone Access")
                .font(.title)
                .fontWeight(.bold)

            Text("Shrava needs access to your microphone\nto transcribe your voice on-device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if hasMicPermission {
                Label("Permission granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Microphone Access") {
                    Task {
                        hasMicPermission = await appState.requestMicrophonePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding()
    }

    private var keyboardStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 80))
                .foregroundStyle(.purple)

            Text("Keyboard Extension")
                .font(.title)
                .fontWeight(.bold)

            Text("Install the Shrava Keyboard to start dictation from any app. The large Whisper model runs in the main app (memory limits prevent loading it inside the keyboard).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Go to Settings → General → Keyboard")
                Text("2. Tap \"Keyboards\" → \"Add New Keyboard\"")
                Text("3. Select \"Shrava Keyboard\"")
                Text("4. Enable \"Allow Full Access\"")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    private var completeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Tap and hold the record button\nto start dictating.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var navigationButtons: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
            }

            Spacer()

            if currentStep < 4 {
                Button("Next") {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentStep == 1 && !appState.modelReady)
            } else {
                Button("Get Started") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.modelReady)
            }
        }
        .padding()
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
}
