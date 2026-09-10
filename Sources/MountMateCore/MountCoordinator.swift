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

    /// The task consuming every source. `nil` until `start()`.
    private var consumption: Task<Void, Never>?

    /// Continuation for `statuses`. Created once in `init` so a snapshot emitted
    /// before anyone iterates is buffered rather than dropped.
    private let statusContinuation: AsyncStream<[EndpointStatus]>.Continuation
    private let statusStream: AsyncStream<[EndpointStatus]>

    private let log: (any ActivityLog)?
    /// The snapshot the last publish produced, for diffing. `nil` until the first.
    private var previousSnapshot: [EndpointStatus]?

    public init(
        engine: MountEngine,
        endpointsProvider: @escaping @Sendable () async -> [ShareEndpoint],
        sources: [any TriggerSource],
        scheduler: any Scheduler = SystemScheduler(),
        log: (any ActivityLog)? = nil
    ) {
        self.engine = engine
        self.endpointsProvider = endpointsProvider
        self.sources = sources
        self.scheduler = scheduler
        self.log = log

        var captured: AsyncStream<[EndpointStatus]>.Continuation!
        statusStream = AsyncStream { captured = $0 }
        statusContinuation = captured
    }

    /// Snapshots of every endpoint, emitted after each attempt.
    ///
    /// The coordinator is the only component that knows when state changed, so the
    /// UI observes this rather than polling the engine on a timer of its own.
    public var statuses: AsyncStream<[EndpointStatus]> { statusStream }

    private func publishSnapshot() async {
        var snapshot: [EndpointStatus] = []
        for endpoint in await endpointsProvider() {
            snapshot.append(
                EndpointStatus(
                    id: endpoint.id,
                    displayName: endpoint.displayName,
                    state: await engine.state(for: endpoint.id),
                    enabled: endpoint.enabled
                )
            )
        }
        if let log {
            for entry in TransitionLogger.entries(
                from: previousSnapshot, to: snapshot, at: Date()
            ) {
                await log.append(entry)
            }
        }
        previousSnapshot = snapshot

        statusContinuation.yield(snapshot)
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

    /// Emits `.launch`, then follows every source until `stop()`.
    ///
    /// Idempotent: calling it twice does not start a second consumer.
    public func start() {
        guard consumption == nil else { return }

        let sources = self.sources
        consumption = Task { [weak self, log] in
            await log?.append(
                ActivityEntry(category: .lifecycle, share: nil, message: "started")
            )
            await self?.handle(.launch)

            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    // Each child closure takes its own weak capture. Reaching through
                    // the outer `self?` here instead would capture a mutable var
                    // shared with the enclosing task, which Swift 6 rejects outright.
                    group.addTask { [weak self] in
                        for await event in source.events {
                            await self?.handle(event)
                        }
                    }
                }
            }
        }
    }

    /// Stops consuming and cancels every pending retry. Safe to call more than once.
    public func stop() {
        if let log {
            // Detached because `stop()` is not async and must stay callable from
            // teardown paths that cannot await.
            Task {
                await log.append(
                    ActivityEntry(category: .lifecycle, share: nil, message: "stopped")
                )
            }
        }
        consumption?.cancel()
        consumption = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        statusContinuation.finish()
    }

    /// One pass over a single endpoint, plus whatever retry that pass earned.
    private func visit(_ endpoint: ShareEndpoint) async {
        await engine.ensureMounted(endpoint)
        await scheduleRetry(for: endpoint)
        await publishSnapshot()
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
