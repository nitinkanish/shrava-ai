import SwiftUI
import ShravaCore

struct RecordingView: View {
    @EnvironmentObject var appState: IOSAppState
    @Namespace private var recordNS
    @State private var holding = false

    var body: some View {
        NavigationStack {
            ZStack {
                ShravaTheme.softBackground
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    header
                    Spacer(minLength: 8)
                    heroGlass
                    statusBlock
                    Spacer(minLength: 8)
                    holdToRecordControl
                    if appState.showingResult {
                        resultCard
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("ShravaLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("Shrava")
                            .font(.headline.weight(.semibold))
                    }
                }
                if appState.launchedFromKeyboard && !appState.isRecording && appState.showingResult {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { appState.launchedFromKeyboard = false }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(ShravaTheme.tagline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if !appState.modelReady {
                Text("Download the Whisper model in Settings to start.")
                    .font(.caption)
                    .foregroundStyle(ShravaTheme.coral)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    private var heroGlass: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(spacing: 20) {
                WaveformBars(samples: appState.isRecording ? appState.waveformSamples : breathingSamples)
                    .frame(height: 72)
                    .padding(.horizontal, 8)
                    .glassEffectID("waveform", in: recordNS)

                ZStack {
                    if appState.isRecording {
                        Circle()
                            .stroke(ShravaTheme.coral.opacity(0.35), lineWidth: 10)
                            .frame(width: 150, height: 150)
                            .scaleEffect(1.05 + CGFloat(appState.audioLevel) * 0.2)
                            .glassEffectID("pulse", in: recordNS)
                    }

                    Button {
                        // Tap toggles when not using press-and-hold path.
                    } label: {
                        ZStack {
                            Circle()
                                .fill(ShravaTheme.brandGradient.opacity(0.001))
                                .frame(width: 118, height: 118)
                            if appState.isProcessing {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                            } else {
                                Image(systemName: appState.isRecording ? "waveform" : "mic.fill")
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .symbolEffect(.variableColor.iterative, isActive: appState.isRecording)
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(appState.isRecording ? ShravaTheme.coral : ShravaTheme.purple)
                    .disabled(appState.isProcessing)
                    .glassEffectID("mic", in: recordNS)
                    .simultaneousGesture(pressHoldGesture)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .shravaGlass(.regular.tint(ShravaTheme.purple.opacity(0.35)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
    }

    private var breathingSamples: [Float] {
        let t = Date().timeIntervalSinceReferenceDate
        return (0..<32).map { i in
            Float(0.18 + 0.12 * abs(sin(t * 1.4 + Double(i) * 0.35)))
        }
    }

    private var statusBlock: some View {
        VStack(spacing: 8) {
            if appState.isRecording {
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Listening…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if appState.isProcessing {
                Text("Transcribing on-device…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if let error = appState.lastError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(ShravaTheme.coral)
                    .multilineTextAlignment(.center)
            } else {
                Text("Hold to capture")
                    .font(.title3.weight(.semibold))
                Text("Release to transcribe with Whisper")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: appState.isRecording)
    }

    private var holdToRecordControl: some View {
        Text(appState.isRecording ? "Release to stop" : "Press & hold")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .shravaGlass(
                .regular.tint(appState.isRecording ? ShravaTheme.coral.opacity(0.4) : ShravaTheme.purple.opacity(0.25)),
                in: Capsule(),
                interactive: true
            )
            .opacity(appState.isProcessing ? 0.5 : 1)
            .allowsHitTesting(false)
    }

    private var pressHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !holding, !appState.isRecording, !appState.isProcessing else { return }
                holding = true
                Task { await appState.startRecording() }
            }
            .onEnded { _ in
                holding = false
                if appState.isRecording {
                    Task { await appState.stopRecordingAndTranscribe() }
                }
            }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(appState.lastTranscription)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button { appState.copyToClipboard() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                if appState.launchedFromKeyboard {
                    Button { appState.launchedFromKeyboard = false } label: {
                        Label("Insert", systemImage: "text.insert")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ShravaTheme.purple)
                }
                Spacer()
                Button {
                    appState.currentTab = .history
                } label: {
                    Label("History", systemImage: "clock")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(18)
        .shravaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
