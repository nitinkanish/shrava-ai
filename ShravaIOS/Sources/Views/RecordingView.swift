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

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        heroGlass
                        statusBlock
                        longRecordingControls
                        quickHoldHint
                        if appState.showingResult {
                            resultCard
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
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
                        // Mic is press-and-hold for quick capture; long recording uses the button below.
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
                                Image(systemName: micSymbol)
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .symbolEffect(.variableColor.iterative, isActive: appState.isRecording && !appState.isPaused)
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

    private var micSymbol: String {
        if appState.isRecording {
            return appState.isLongRecording ? "stop.fill" : "waveform"
        }
        return "mic.fill"
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
                Text(statusCaption)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if appState.isProcessing {
                VStack(spacing: 10) {
                    Text("Transcribing on-device…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: appState.transcriptionProgress)
                        .tint(ShravaTheme.purple)
                        .padding(.horizontal, 24)
                    Text("\(Int(appState.transcriptionProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let error = appState.lastError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(ShravaTheme.coral)
                    .multilineTextAlignment(.center)
            } else {
                Text("Meetings & quick capture")
                    .font(.title3.weight(.semibold))
                Text("Start a long recording, or hold the mic for a quick note")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.snappy, value: appState.isRecording)
    }

    private var statusCaption: String {
        if appState.isPaused { return "Paused — tap Resume" }
        if appState.isLongRecording { return "Long recording · Dynamic Island active" }
        return "Listening…"
    }

    private var longRecordingControls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await appState.toggleLongRecording() }
            } label: {
                Label(
                    appState.isRecording && appState.isLongRecording ? "Stop & Transcribe" : "Start long recording",
                    systemImage: appState.isRecording && appState.isLongRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.glassProminent)
            .tint(appState.isRecording && appState.isLongRecording ? ShravaTheme.coral : ShravaTheme.purple)
            .disabled(appState.isProcessing || (appState.isRecording && !appState.isLongRecording))

            if appState.isRecording && appState.isLongRecording {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            if appState.isPaused {
                                await appState.resumeLongRecording()
                            } else {
                                await appState.pauseLongRecording()
                            }
                        }
                    } label: {
                        Label(appState.isPaused ? "Resume" : "Pause", systemImage: appState.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.glass)

                    Button {
                        Task { await appState.cancelRecording() }
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var quickHoldHint: some View {
        Text(appState.isRecording && !appState.isLongRecording ? "Release to stop" : "Press & hold mic for quick capture")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .shravaGlass(
                .regular.tint(appState.isRecording && !appState.isLongRecording ? ShravaTheme.coral.opacity(0.4) : ShravaTheme.purple.opacity(0.25)),
                in: Capsule(),
                interactive: true
            )
            .opacity(appState.isProcessing || (appState.isRecording && appState.isLongRecording) ? 0.45 : 1)
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
                let wasHolding = holding
                holding = false
                if wasHolding, appState.isRecording, !appState.isLongRecording {
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
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
