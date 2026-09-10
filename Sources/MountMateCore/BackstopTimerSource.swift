import Foundation

/// Fires every `interval`, forever.
///
/// Spec §5.4: this bounds the cost of a *missed* event at 5 minutes rather than
/// however long the machine stays up. It is also the health probe — `ensureMounted`
/// re-probes a mounted endpoint and remounts it if it has gone dead — so there is no
/// separate liveness timer anywhere in this package.
public struct BackstopTimerSource: TriggerSource {
    public let interval: Duration
    private let scheduler: any Scheduler

    public init(
        interval: Duration = .seconds(300),
        scheduler: any Scheduler = SystemScheduler()
    ) {
        self.interval = interval
        self.scheduler = scheduler
    }

    public var events: AsyncStream<TriggerEvent> {
        let interval = self.interval
        let scheduler = self.scheduler

        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await scheduler.sleep(for: interval)
                    } catch {
                        break
                    }
                    continuation.yield(.backstop)
                }
                continuation.finish()
            }
            // Breaking out of the consuming `for await` must stop the timer, or the
            // task outlives its stream and leaks for the life of the process.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
