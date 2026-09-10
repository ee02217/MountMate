import Foundation

/// The one way this package waits.
///
/// Everything that sleeps goes through here so tests can drive the schedule without
/// wall-clock time. `MountEngine` needs no such seam — it never sleeps — so this is
/// deliberately confined to the trigger layer.
public protocol Scheduler: Sendable {
    /// Suspends for `duration`. Throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
}

public struct SystemScheduler: Scheduler {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
