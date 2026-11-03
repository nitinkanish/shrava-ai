import SwiftUI
import MurmurCore

struct IOSOnboardingView: View {
    @EnvironmentObject var appState: IOSAppState
    @Binding var isPresented: Bool
    
    @State private var currentStep = 0
    @State private var apiKey = ""
    @State private var hasMicPermission = false
    
    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $currentStep) {
                    welcomeStep
                        .tag(0)
                    
                    apiKeyStep
                        .tag(1)
                    
                    microphoneStep
                        .tag(2)
                    
                    keyboardStep
                        .tag(3)
                    
                    completeStep
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                
                navigationButtons
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            hasMicPermission = appState.hasMicrophonePermission
        }
    }
    
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.blue)
            
            Text("Welcome to Murmur")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Voice dictation powered by AI.\nSpeak naturally and get clean, polished text.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .padding()
    }
    
    private var apiKeyStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "key.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
            
            Text("OpenAI API Key")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Murmur uses OpenAI's API for transcription.\nYour key is stored securely in the Keychain.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            SecureField("sk-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 32)
            
            Link("Get an API key from OpenAI →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.footnote)
            
            Spacer()
        }
        .padding()
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
            
            Text("Murmur needs access to your microphone\nto transcribe your voice.")
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
            
            Text("Install the Murmur Keyboard to dictate\ntext in any app.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Go to Settings → General → Keyboard")
                Text("2. Tap \"Keyboards\" → \"Add New Keyboard\"")
                Text("3. Select \"Murmur Keyboard\"")
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
                    withAnimation {
                        currentStep -= 1
                    }
                }
            }
            
            Spacer()
            
            if currentStep < 4 {
                Button("Next") {
                    if currentStep == 1 && !apiKey.isEmpty {
                        try? KeychainManager.shared.saveOpenAIAPIKey(apiKey)
                        appState.refreshAPIKey()
                    }
                    withAnimation {
                        currentStep += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentStep == 1 && apiKey.isEmpty)
            } else {
                Button("Get Started") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
