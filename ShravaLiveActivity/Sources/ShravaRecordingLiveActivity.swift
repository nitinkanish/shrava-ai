import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct ShravaRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        pulsingMic
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording")
                                .font(.headline.weight(.semibold))
                            Text(context.attributes.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedView(context: context)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(
                            context.state.isPaused ? "Paused" : "Listening",
                            systemImage: context.state.isPaused ? "pause.fill" : "waveform"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(brandCoral)
                        Spacer()
                        Button(intent: StopRecordingIntent()) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background(brandCoral, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                pulsingMic
                    .padding(.leading, 4)
            } compactTrailing: {
                elapsedView(context: context)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandCoral)
                    .padding(.trailing, 4)
            } minimal: {
                Circle()
                    .fill(brandCoral)
                    .frame(width: 10, height: 10)
            }
            .keylineTint(brandPurple)
        }
    }

    private var brandCoral: Color { Color(red: 0.97, green: 0.22, blue: 0.20) }
    private var brandPurple: Color { Color(red: 0.42, green: 0.28, blue: 0.92) }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [brandPurple, Color(red: 0.72, green: 0.22, blue: 0.78), brandCoral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .font(.body.weight(.bold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Shrava · Recording")
                    .font(.headline)
                Text(context.attributes.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                elapsedView(context: context)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Button(intent: StopRecordingIntent()) {
                    Text("Stop")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(brandCoral, in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    }

    private var pulsingMic: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(brandCoral)
            .symbolEffect(.pulse, options: .repeating)
    }

    @ViewBuilder
    private func elapsedView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.isPaused {
            Text(formatElapsed(context.state.frozenElapsed))
        } else {
            Text(
                timerInterval: context.state.timerStart...Date.distantFuture,
                countsDown: false,
                showsHours: true
            )
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let e = max(0, Int(t))
        let h = e / 3600
        let m = (e % 3600) / 60
        let s = e % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
