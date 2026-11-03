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
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(brandCoral)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("Recording")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedView(context: context)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.state.isPaused
                             ? (context.state.pauseReason ?? "Paused")
                             : "Meeting")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Button(intent: StopRecordingIntent()) {
                            Text("Stop")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .background(brandCoral, in: Capsule())
                        .foregroundStyle(.white)
                    }
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
            .keylineTint(brandPurple)
        }
    }

    private var brandCoral: Color { Color(red: 0.97, green: 0.22, blue: 0.20) }
    private var brandPurple: Color { Color(red: 0.42, green: 0.28, blue: 0.92) }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
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
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .font(.caption.weight(.bold))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Shrava")
                    .font(.subheadline.weight(.semibold))
                Text(context.state.isPaused
                     ? (context.state.pauseReason ?? "Paused")
                     : "Recording")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            elapsedView(context: context)
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(width: 56, alignment: .trailing)

            Button(intent: StopRecordingIntent()) {
                Text("Stop")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .background(brandCoral, in: Capsule())
            .foregroundStyle(.white)
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
