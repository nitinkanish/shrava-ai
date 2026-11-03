import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

@available(iOS 18.0, *)
struct RecordingControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        !Activity<RecordingActivityAttributes>.activities.isEmpty
    }
}

/// Control Center / Lock Screen / Action Button control — toggles recording without opening the app.
@available(iOS 18.0, *)
struct ShravaRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ShravaControlKind.recording, provider: RecordingControlValueProvider()) { isRecording in
            ControlWidgetToggle(isOn: isRecording, action: ToggleRecordingIntent()) {
                Label(
                    isRecording ? "Stop Shrava" : "Record Shrava",
                    systemImage: isRecording ? "stop.fill" : "mic.fill"
                )
            }
            .tint(Color(red: 0.97, green: 0.22, blue: 0.20))
        }
        .displayName("Shrava Recording")
        .description("Start or stop a long meeting recording without opening Shrava.")
    }
}
