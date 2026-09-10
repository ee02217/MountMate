import Foundation
import Network

/// Turns a stream of path statuses into trigger events.
///
/// Pure and synchronous so the rule that matters — only `unsatisfied -> satisfied`
/// counts as a reconnect — is testable without a network. Losing the path emits
/// nothing at all: there is no point sweeping endpoints when there is no route.
struct PathTransitionFilter {
    private var lastSatisfied: Bool?

    mutating func event(forSatisfied satisfied: Bool) -> TriggerEvent? {
        defer { lastSatisfied = satisfied }

        guard satisfied else { return nil }
        return lastSatisfied == true ? .networkChanged : .networkBecameSatisfied
    }
}

/// A `Sendable` box for the filter: `NWPathMonitor` calls back on its own queue.
private final class FilterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var filter = PathTransitionFilter()

    func event(forSatisfied satisfied: Bool) -> TriggerEvent? {
        lock.lock()
        defer { lock.unlock() }
        return filter.event(forSatisfied: satisfied)
    }
}

/// Network changes, as seen by `NWPathMonitor`.
public struct NetworkTriggerSource: TriggerSource {
    public init() {}

    public var events: AsyncStream<TriggerEvent> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let box = FilterBox()

            monitor.pathUpdateHandler = { path in
                if let event = box.event(forSatisfied: path.status == .satisfied) {
                    continuation.yield(event)
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.sergio.mountmate.network"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }
}
