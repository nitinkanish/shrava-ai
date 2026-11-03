import WidgetKit
import SwiftUI

@main
struct ShravaLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ShravaRecordingLiveActivity()
        if #available(iOS 18.0, *) {
            ShravaRecordingControl()
        }
    }
}
