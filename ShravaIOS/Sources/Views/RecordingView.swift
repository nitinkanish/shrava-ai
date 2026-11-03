import SwiftUI
import ShravaCore

struct RecordingView: View {
    @EnvironmentObject var appState: IOSAppState
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                
                recordingIndicator
                
                statusText
                
                Spacer()
                
                recordButton
                
                if appState.showingResult {
                    resultView
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Shrava")
            .toolbar {
                if appState.launchedFromKeyboard && !appState.isRecording && appState.showingResult {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            appState.launchedFromKeyboard = false
                        }
                    }
                }
            }
        }
    }
    
    private var recordingIndicator: some View {
        ZStack {
            if appState.isRecording {
                Circle()
                    .fill(.red.opacity(0.2))
                    .frame(width: 180, height: 180)
                    .scaleEffect(waveScale)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: waveScale)
            }
            
            Circle()
                .fill(appState.isRecording ? .red : (appState.isProcessing ? .orange : .blue))
                .frame(width: 120, height: 120)
            
            if appState.isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
            } else {
                Image(systemName: appState.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
            }
        }
    }
    
    @State private var waveScale: CGFloat = 1.0
    
    private var statusText: some View {
        VStack(spacing: 8) {
            if appState.isRecording {
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(.primary)
                
                Text("Recording...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if appState.isProcessing {
                Text("Processing...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if let error = appState.lastError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("Tap and hold to record")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            waveScale = 1.3
        }
    }
    
    private var recordButton: some View {
        Button(action: {}) {
            Text(appState.isRecording ? "Release to Stop" : "Hold to Record")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(appState.isRecording ? .red : .blue)
                .cornerRadius(16)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !appState.isRecording && !appState.isProcessing {
                        Task {
                            await appState.startRecording()
                        }
                    }
                }
                .onEnded { _ in
                    if appState.isRecording {
                        Task {
                            await appState.stopRecordingAndTranscribe()
                        }
                    }
                }
        )
        .disabled(appState.isProcessing)
        .padding(.horizontal, 32)
    }
    
    private var resultView: some View {
        VStack(spacing: 12) {
            Text("Result")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(appState.lastTranscription)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
            
            HStack(spacing: 16) {
                Button(action: { appState.copyToClipboard() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                
                if appState.launchedFromKeyboard {
                    Button(action: { returnToKeyboard() }) {
                        Label("Insert", systemImage: "text.insert")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
    
    private func returnToKeyboard() {
        // The transcription is already written to App Group
        // User can switch back to the previous app manually
        appState.launchedFromKeyboard = false
    }
}
