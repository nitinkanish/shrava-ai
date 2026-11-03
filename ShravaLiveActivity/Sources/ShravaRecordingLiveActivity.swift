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
                        Image(systemName: context.state.isPaused ? "pause.circle.fill" : "mic.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(brandCoral)
                            .symbolEffect(context.state.isPaused ? .pulse.byLayer : .pulse, options: .repeating)
                        Text(context.state.isPaused ? "Paused" : "Recording")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedView(context: context)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 48, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        if context.state.isPaused {
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
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(brandCoral)
                    .symbolEffect(.pulse, options: .repeating)
                    .padding(.leading, 1)
            } compactTrailing: {
                elapsedView(context: context)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandCoral)
                    .frame(maxWidth: 44, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 2)
            } minimal: {
                Circle()
                    .fill(brandCoral)
                    .frame(width: 8, height: 8)
            }
            .widgetURL(URL(string: "shrava://live"))
            .keylineTint(brandPurple)
        }
    }

    private var brandCoral: Color { Color(red: 0.97, green: 0.22, blue: 0.20) }
    private var brandPurple: Color { Color(red: 0.42, green: 0.28, blue: 0.92) }

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
                    Image(systemName: context.state.isPaused ? "pause.fill" : "mic.fill")
                        .foregroundStyle(.white)
                        .font(.caption.weight(.bold))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Shrava")
                        .font(.subheadline.weight(.semibold))
                    Text(context.state.isPaused
                         ? (context.state.pauseReason ?? "Paused")
                         : context.attributes.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 4)

                elapsedView(context: context)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 56, alignment: .trailing)
            }

            HStack(spacing: 10) {
                if context.state.isPaused {
                    Button(intent: ResumeRecordingIntent()) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .tint(.green)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(intent: PauseRecordingIntent()) {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .tint(.orange)
                    .buttonStyle(.bordered)
                }

                Button(intent: StopRecordingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .tint(brandCoral)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    }

    @ViewBuilder
    private func elapsedView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.isPaused {
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
