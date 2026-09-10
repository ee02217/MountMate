import Foundation

/// Fires every `interval`, forever.
///
/// Spec §5.4: this bounds the cost of a *missed* event at 5 minutes rather than
/// however long the machine stays up. It is also the health probe — `ensureMounted`
/// re-probes a mounted endpoint and remounts it if it has gone dead — so there is no
/// separate liveness timer anywhere in this package.
public struct BackstopTimerSource: TriggerSource {
    private let interval: @Sendable () async -> Duration
    private let scheduler: any Scheduler

    /// Reads the interval before each sleep, so a preference change lands on the next
    /// cycle (spec §8.2). Taking it once would mean restarting the coordinator to
    /// apply a change — and `stop()` finishes the status stream, which cannot be
    /// un-finished.
    public init(
        interval: @escaping @Sendable () async -> Duration,
        scheduler: any Scheduler = SystemScheduler()
    ) {
        self.interval = interval
        self.scheduler = scheduler
    }

    /// A fixed interval, for callers with nothing to configure.
    public init(
        interval: Duration = .seconds(300),
        scheduler: any Scheduler = SystemScheduler()
    ) {
        self.init(interval: { interval }, scheduler: scheduler)
    }

    public var events: AsyncStream<TriggerEvent> {
        let interval = self.interval
        let scheduler = self.scheduler

        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await scheduler.sleep(for: await interval())
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
