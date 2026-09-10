import Foundation

/// Decides *when* the engine runs.
///
/// The engine deliberately never sleeps or schedules — it computes `retryDelay(for:)`
/// and stops. This actor is the other half: it listens to trigger sources, sweeps
/// endpoints through `ensureMounted`, and owns every timer in the system.
public actor MountCoordinator {
    private let engine: MountEngine
    private let endpointsProvider: @Sendable () async -> [ShareEndpoint]
    private let sources: [any TriggerSource]
    private let scheduler: any Scheduler

    /// One pending retry per endpoint. Replacing an entry cancels the old one, so a
    /// trigger arriving mid-ladder reschedules rather than stacking a second timer.
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        engine: MountEngine,
        endpointsProvider: @escaping @Sendable () async -> [ShareEndpoint],
        sources: [any TriggerSource],
        scheduler: any Scheduler = SystemScheduler()
    ) {
        self.engine = engine
        self.endpointsProvider = endpointsProvider
        self.sources = sources
        self.scheduler = scheduler
    }

    /// Acts on one trigger.
    ///
    /// Public rather than private so tests drive the coordinator directly instead of
    /// through a stream, which keeps them free of any timing assumption.
    public func handle(_ event: TriggerEvent) async {
        // Before the sweep, so this event's own attempt starts from a clean ladder.
        if event.resetsBackoff {
            await engine.resetBackoff()
        }

        switch event {
        case .userRequested(.some(let id)):
            guard let endpoint = await endpointsProvider().first(where: { $0.id == id })
            else { return }
            await visit(endpoint)
        default:
            for endpoint in await endpointsProvider() {
                await visit(endpoint)
            }
        }
    }

    /// Cancels every pending retry. Safe to call more than once.
    public func stop() {
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
    }

    /// One pass over a single endpoint, plus whatever retry that pass earned.
    private func visit(_ endpoint: ShareEndpoint) async {
        await engine.ensureMounted(endpoint)
        await scheduleRetry(for: endpoint)
    }

    private func scheduleRetry(for endpoint: ShareEndpoint) async {
        retryTasks.removeValue(forKey: endpoint.id)?.cancel()

        // nil means the engine has nothing to retry: either the endpoint is mounted,
        // or `resetBackoff()` landed after its attempt failed. Both are rescued by the
        // backstop sweep, so leaving nothing scheduled here is correct.
        guard let delay = await engine.retryDelay(for: endpoint.id) else { return }

        let scheduler = self.scheduler
        retryTasks[endpoint.id] = Task { [weak self] in
            do {
                try await scheduler.sleep(for: delay)
            } catch {
                return  // cancelled while waiting
            }
            guard !Task.isCancelled else { return }
            await self?.retryFired(for: endpoint)
        }
    }

    /// Runs the retry after detaching its own handle.
    ///
    /// Detaching first matters. `visit` calls `scheduleRetry`, which cancels the
    /// stored task for this endpoint — and at this point that stored task is *this*
    /// one, still running. Cancelling ourselves mid-`ensureMounted` would surface as
    /// `CancellationError` inside the engine, which treats cancellation as "shutting
    /// down" and returns *without recording the failure or advancing backoff*. The
    /// ladder would silently stop growing.
    private func retryFired(for endpoint: ShareEndpoint) async {
        retryTasks.removeValue(forKey: endpoint.id)
        await visit(endpoint)
    }
}
