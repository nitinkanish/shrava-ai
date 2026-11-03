import Foundation
import CallKit
import OSLog

/// Observes cellular / FaceTime calls. Third-party apps cannot capture call audio;
/// we only use this to pause/resume meeting recording around the call.
final class PhoneCallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = PhoneCallMonitor()
    private static let log = Logger(subsystem: "com.shrava.ios", category: "calls")

    private let observer = CXCallObserver()
    /// Called on the main queue whenever call state changes. Argument is `hasActiveCall`.
    var onCallsChanged: ((Bool) -> Void)?

    private override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        Self.log.info("PhoneCallMonitor ready calls=\(self.observer.calls.count)")
    }

    /// A call that still owns the audio route: connected, or outgoing/incoming not yet ended.
    var hasActiveCall: Bool {
        let active = observer.calls.contains { call in
            !call.hasEnded
        }
        return active
    }

    var debugDescriptionCalls: String {
        observer.calls.map { c in
            "id=\(c.uuid.uuidString.prefix(8)) ended=\(c.hasEnded) out=\(c.isOutgoing) connected=\(c.hasConnected) onHold=\(c.isOnHold)"
        }.joined(separator: "; ")
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Self.log.info("callChanged ended=\(call.hasEnded) out=\(call.isOutgoing) connected=\(call.hasConnected) active=\(self.hasActiveCall) all=[\(self.debugDescriptionCalls, privacy: .public)]")
        onCallsChanged?(hasActiveCall)
    }
}
