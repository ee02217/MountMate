import Foundation

/// Where the parts meet.
///
/// The engine takes a password closure, the coordinator takes an endpoints closure,
/// and the stores know nothing of either. This is the composition root that fills
/// those in — and the only place `enabled` is changed, so the persisted flag and the
/// mount action cannot drift apart.
public actor AppController {
    private let endpointStore: any EndpointStore
    private let credentialStore: any CredentialStore
    private let engine: MountEngine
    private let coordinator: MountCoordinator

    /// The most recent load, including what it skipped or quarantined, for the
    /// Diagnostics pane to report.
    public private(set) var lastLoad: EndpointLoad = .empty

    /// The cached endpoint list the coordinator reads through its closure. Held in a
    /// locked box because that closure is `@Sendable` and called from the
    /// coordinator's actor, not this one.
    private let cache = EndpointCache()

    /// `service` and `inspector` are injectable and default to the real ones.
    ///
    /// This is not a convenience. A test that constructs the real pair will happily
    /// match a share this machine actually has mounted and unmount it — the default
    /// test endpoint's `mountFromIdentifier` is an ordinary NAS address, and the
    /// developer's own NAS is exactly the kind of thing mounted at that address.
    /// Tests must pass fakes.
    public init(
        endpointStore: any EndpointStore,
        credentialStore: any CredentialStore,
        sources: [any TriggerSource],
        scheduler: any Scheduler = SystemScheduler(),
        service: any MountService = NetFSMountService(),
        inspector: any MountInspector = SystemMountInspector(),
        log: (any ActivityLog)? = nil,
        notifier: (any Notifier)? = nil
    ) {
        self.endpointStore = endpointStore
        self.credentialStore = credentialStore

        let cache = self.cache
        let credentials = credentialStore
        self.engine = MountEngine(
            service: service,
            inspector: inspector,
            log: log,
            passwordProvider: { endpoint in
                await credentials.password(for: endpoint)
            }
        )
        self.coordinator = MountCoordinator(
            engine: engine,
            endpointsProvider: { cache.endpoints() },
            sources: sources,
            scheduler: scheduler,
            log: log,
            notifier: notifier
        )
    }

    public var statuses: AsyncStream<[EndpointStatus]> {
        get async { await coordinator.statuses }
    }

    public func start() async {
        await reload()
        await coordinator.start()
    }

    public func stop() async {
        await coordinator.stop()
    }

    /// Mounted becomes unmounted-and-disabled; disabled becomes enabled-and-mounted.
    ///
    /// A bare unmount would be undone by the next backstop sweep, so the
    /// disable is what makes it hold.
    public func toggle(_ id: UUID) async throws {
        guard var endpoint = cache.endpoints().first(where: { $0.id == id }) else { return }

        if endpoint.enabled {
            // Unmount first: once it is disabled, `ensureMounted` would refuse to act
            // on it, and the engine's own unmount is the only thing that keeps its
            // state honest.
            try await engine.unmount(endpoint)
            endpoint.enabled = false
        } else {
            endpoint.enabled = true
        }

        var endpoints = cache.endpoints()
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints[index] = endpoint
        cache.set(endpoints)
        try await endpointStore.save(endpoints)

        await coordinator.handle(.userRequested(id))
    }

    /// The endpoints currently in force.
    public var endpoints: [ShareEndpoint] { cache.endpoints() }

    /// The Keychain policy actually in force, for the Diagnostics pane to warn about.
    public var accessPolicy: CredentialAccessPolicy {
        get async { await credentialStore.accessPolicy }
    }

    /// Replaces the endpoint list: persist, refresh the cache, sweep.
    ///
    /// Same order as `toggle` — persist before sweeping, so a crash between the two
    /// leaves the file correct rather than the mounts correct.
    public func apply(_ endpoints: [ShareEndpoint]) async throws {
        try await endpointStore.save(endpoints)
        cache.set(endpoints)
        lastLoad = EndpointLoad(endpoints: endpoints)
        await coordinator.handle(.userRequested(nil))
    }

    /// Re-reads the store. Public because the Settings pane and any external edit to
    /// `endpoints.json` both need it, not only `start()`.
    public func reload() async {
        guard let load = try? await endpointStore.load() else { return }
        lastLoad = load
        cache.set(load.endpoints)
    }
}

/// A `Sendable` box for the endpoint list.
///
/// The coordinator's `endpointsProvider` is a `@Sendable` closure invoked from the
/// coordinator's actor; it cannot reach into `AppController`'s isolation without
/// deadlocking on a toggle that is itself awaiting the coordinator.
final class EndpointCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ShareEndpoint] = []

    func endpoints() -> [ShareEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ endpoints: [ShareEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        stored = endpoints
    }
}
