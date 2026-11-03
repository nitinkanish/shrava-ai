import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct ShravaRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreenView(context: context)
                .widgetURL(URL(string: "shrava://live"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: leadingSymbol(for: context.state.phase))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(leadingColor(for: context.state.phase))
                            .modifier(PulseIfActive(active: context.state.phase == .recording || context.state.phase == .transcribing))
                        Text(leadingTitle(for: context.state.phase))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingView(context: context)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 48, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(centerLine(context: context))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomControls(context: context)
                }
            } compactLeading: {
                Image(systemName: leadingSymbol(for: context.state.phase))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(leadingColor(for: context.state.phase))
                    .modifier(PulseIfActive(active: context.state.phase == .recording || context.state.phase == .transcribing))
                    .padding(.leading, 1)
            } compactTrailing: {
                trailingView(context: context)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(leadingColor(for: context.state.phase))
                    .frame(maxWidth: 52, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 2)
            } minimal: {
                Circle()
                    .fill(leadingColor(for: context.state.phase))
                    .frame(width: 8, height: 8)
            }
            .widgetURL(URL(string: "shrava://live"))
            .keylineTint(brandPurple)
        }
    }

    private var brandCoral: Color { Color(red: 0.97, green: 0.22, blue: 0.20) }
    private var brandPurple: Color { Color(red: 0.42, green: 0.28, blue: 0.92) }

    private func leadingSymbol(for phase: RecordingActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: return "mic.fill"
        case .paused: return "pause.circle.fill"
        case .transcribing: return "waveform"
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func leadingColor(for phase: RecordingActivityAttributes.Phase) -> Color {
        switch phase {
        case .recording: return brandCoral
        case .paused: return .orange
        case .transcribing: return brandPurple
        case .saved: return .green
        case .failed: return .red
        }
    }

    private func leadingTitle(for phase: RecordingActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .transcribing: return "Transcribing"
        case .saved: return "Saved"
        case .failed: return "Failed"
        }
    }

    private func centerLine(context: ActivityViewContext<RecordingActivityAttributes>) -> String {
        switch context.state.phase {
        case .recording:
            return context.attributes.title
        case .paused:
            return context.state.pauseReason ?? "Paused"
        case .transcribing:
            return context.state.pauseReason ?? "Transcribing…"
        case .saved:
            return context.state.pauseReason ?? "Saved ✓"
        case .failed:
            return context.state.pauseReason ?? "Transcription failed"
        }
    }

    @ViewBuilder
    private func trailingView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        switch context.state.phase {
        case .transcribing:
            Text("\(Int((context.state.progress * 100).rounded()))%")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .saved:
            Text("✓")
                .lineLimit(1)
        case .failed:
            Image(systemName: "xmark")
        case .recording, .paused:
            elapsedView(context: context)
        }
    }

    @ViewBuilder
    private func bottomControls(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        switch context.state.phase {
        case .recording, .paused:
            HStack(spacing: 10) {
                if context.state.phase == .paused || context.state.isPaused {
                    Button(intent: ResumeRecordingIntent()) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(intent: PauseRecordingIntent()) {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                    .buttonStyle(.bordered)
                }

                Button(intent: StopRecordingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .tint(brandCoral)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)
        case .transcribing:
            Text(context.state.pauseReason ?? "Transcribing…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        case .saved:
            Text(context.state.pauseReason ?? "Saved ✓")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        case .failed:
            Text(context.state.pauseReason ?? "Transcription failed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [brandPurple, brandCoral],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: leadingSymbol(for: context.state.phase))
                        .foregroundStyle(.white)
                        .font(.caption.weight(.bold))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Shrava")
                        .font(.subheadline.weight(.semibold))
                    Text(centerLine(context: context))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 4)

                trailingView(context: context)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 56, alignment: .trailing)
            }

            bottomControls(context: context)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    }

    @ViewBuilder
    private func elapsedView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.isPaused || context.state.phase == .paused {
            Text(formatElapsed(context.state.frozenElapsed))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(
                timerInterval: context.state.timerStart...Date.distantFuture,
                countsDown: false,
                showsHours: false
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.trailing)
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let e = max(0, Int(t))
        let m = e / 60
        let s = e % 60
        return String(format: "%d:%02d", m, s)
    }
}


private struct PulseIfActive: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.symbolEffect(.pulse, options: .repeating)
        } else {
            content
        }
    }
}
