import SwiftUI
import ShravaCore

struct ContentView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var showingOnboarding = false
    @Namespace private var glassNS

    var body: some View {
        TabView(selection: $appState.currentTab) {
            RecordingView()
                .environmentObject(appState)
                .tabItem { Label("Record", systemImage: "waveform.circle.fill") }
                .tag(IOSAppState.Tab.record)

            IOSHistoryView()
                .environmentObject(appState)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(IOSAppState.Tab.history)

            IOSDictionaryView()
                .environmentObject(appState)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed.fill") }
                .tag(IOSAppState.Tab.dictionary)

            IOSSettingsView()
                .environmentObject(appState)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(IOSAppState.Tab.settings)
        }
        .tint(ShravaTheme.purple)
        .preferredColorScheme(.dark)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: appState.currentTab != .record) {
            FloatingRecordAccessory()
                .environmentObject(appState)
        }
        .onAppear {
            checkOnboarding()
            appState.applyScreenshotTabIfNeeded()
        }
        .sheet(isPresented: $showingOnboarding) {
            IOSOnboardingView(isPresented: $showingOnboarding)
                .environmentObject(appState)
        }
    }

    private func checkOnboarding() {
        appState.refreshModelStatus()
        if !appState.modelReady || !appState.hasMicrophonePermission {
            showingOnboarding = true
        }
    }
}

/// Compact glass record control shown above the tab bar on non-Record tabs.
struct FloatingRecordAccessory: View {
    @EnvironmentObject var appState: IOSAppState
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let compact = placement == .inline
        HStack(spacing: compact ? 10 : 14) {
            WaveformBars(samples: appState.isRecording ? appState.waveformSamples : idleSamples, barCount: compact ? 12 : 18)
                .frame(height: compact ? 18 : 28)
                .frame(maxWidth: compact ? 80 : 140)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                if !compact {
                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await toggleRecord() }
            } label: {
                Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                    .font(compact ? .body.weight(.bold) : .title3.weight(.bold))
                    .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
            }
            .buttonStyle(.glassProminent)
            .tint(appState.isRecording ? ShravaTheme.coral : ShravaTheme.purple)
            .disabled(appState.isProcessing)
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 6 : 10)
    }

    private var idleSamples: [Float] {
        Array(repeating: 0.12, count: 18)
    }

    private var statusTitle: String {
        if appState.isRecording { return formatDuration(appState.recordingDuration) }
        if appState.isProcessing { return "Transcribing…" }
        return "Quick capture"
    }

    private var statusSubtitle: String {
        if appState.isRecording { return "Tap stop when finished" }
        if appState.isProcessing { return "On-device Whisper" }
        return "Hold mic on Record for press-and-hold"
    }

    private func toggleRecord() async {
        if appState.isRecording {
            await appState.stopRecordingAndTranscribe()
            appState.currentTab = .record
        } else if !appState.isProcessing {
            appState.currentTab = .record
            await appState.startRecording()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct WaveformBars: View {
    let samples: [Float]
    var barCount: Int = 32

    var body: some View {
        GeometryReader { geo in
            let count = min(barCount, samples.count)
            let bars = Array(samples.suffix(count))
            HStack(alignment: .center, spacing: max(2, geo.size.width / CGFloat(max(count * 4, 1)))) {
                ForEach(0..<count, id: \.self) { i in
                    let h = max(0.08, CGFloat(bars[i]))
                    Capsule()
                        .fill(ShravaTheme.brandGradient)
                        .frame(width: max(2, geo.size.width / (CGFloat(count) * 2.2)), height: geo.size.height * h)
                        .opacity(0.55 + Double(bars[i]) * 0.45)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .animation(.easeOut(duration: 0.08), value: samples)
    }
}
