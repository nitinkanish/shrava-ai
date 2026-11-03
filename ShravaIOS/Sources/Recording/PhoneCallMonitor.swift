import Foundation
import CallKit

/// Observes cellular / FaceTime calls. Third-party apps cannot capture call audio;
/// we only use this to pause/resume meeting recording around the call.
final class PhoneCallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = PhoneCallMonitor()

    private let observer = CXCallObserver()
    /// Called on the main queue whenever call state changes. Argument is `hasActiveCall`.
    var onCallsChanged: ((Bool) -> Void)?

    private override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var hasActiveCall: Bool {
        observer.calls.contains { !$0.hasEnded }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onCallsChanged?(hasActiveCall)
    }
}
