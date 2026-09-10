import Foundation
import AppKit

/// Holds an observer token so it can be removed from a `@Sendable` closure.
///
/// `addObserver(forName:object:queue:using:)` hands back an `any NSObjectProtocol`,
/// which is not `Sendable`, so capturing it directly in `onTermination` is rejected.
/// The lock makes the box genuinely safe rather than merely silencing the checker.
private final class ObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(center: NotificationCenter) { self.center = center }

    func set(_ token: any NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }
}

/// Wake from sleep, via `NSWorkspace`.
///
/// This is the reason `MountMateCore` links AppKit (spec §5.4, "Cost"): there is no
/// non-AppKit notification for wake. The centre and name are injectable so the
/// behaviour is testable without a real sleep/wake cycle.
public struct WakeTriggerSource: TriggerSource {
    private let center: NotificationCenter
    private let name: Notification.Name

    public init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        name: Notification.Name = NSWorkspace.didWakeNotification
    ) {
        self.center = center
        self.name = name
    }

    public var events: AsyncStream<TriggerEvent> {
        let center = self.center
        let name = self.name

        return AsyncStream { continuation in
            let holder = ObserverToken(center: center)
            holder.set(
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    continuation.yield(.wake)
                }
            )
            continuation.onTermination = { _ in holder.remove() }
        }
    }
}
