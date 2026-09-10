import Foundation

/// Owns all mount state. Deliberately does not sleep or schedule: it computes
/// `retryDelay(for:)` and lets the trigger layer decide when to call back. That keeps
/// the state machine deterministic under test — no fake clocks required.
public actor MountEngine {
    private let service: any MountService
    private let inspector: any MountInspector
    private let backoff: BackoffPolicy
    private let mountDeadline: Duration
    private let passwordProvider: @Sendable (ShareEndpoint) async -> String?

    private var states: [UUID: MountState] = [:]
    private var attempts: [UUID: Int] = [:]
    /// Endpoint ids with an `ensureMounted` call currently in flight. `ensureMounted`
    /// suspends at several `await` points (mount-table lookup, responsiveness probe,
    /// password fetch, the mount itself); without this guard, two near-simultaneous
    /// triggers for the same endpoint (a real scenario once the trigger layer fires on
    /// network changes, wake, and a timer) can both race past the "already mounted"
    /// check and both call `service.mount`, mounting the same share twice.
    private var inFlight: Set<UUID> = []

    public init(
        service: any MountService,
        inspector: any MountInspector,
        backoff: BackoffPolicy = .standard,
        mountDeadline: Duration = .seconds(45),
        passwordProvider: @escaping @Sendable (ShareEndpoint) async -> String?
    ) {
        self.service = service
        self.inspector = inspector
        self.backoff = backoff
        self.mountDeadline = mountDeadline
        self.passwordProvider = passwordProvider
    }

    public func state(for id: UUID) -> MountState {
        states[id] ?? .idle
    }

    /// The delay before the next attempt, or nil if there is nothing to retry.
    public func retryDelay(for id: UUID) -> Duration? {
        guard let count = attempts[id], count > 0 else { return nil }
        return backoff.delay(forAttempt: count)
    }

    /// Called on a network change: a changed path invalidates prior failures.
    public func resetBackoff() {
        attempts.removeAll()
    }

    public func ensureMounted(_ endpoint: ShareEndpoint) async {
        guard endpoint.enabled else {
            states[endpoint.id] = .idle
            return
        }

        // No `await` between the check and the insert: on an actor that makes the
        // pair atomic, so a concurrent call for the same endpoint bails out instead
        // of racing this one to `service.mount`.
        guard !inFlight.contains(endpoint.id) else { return }
        inFlight.insert(endpoint.id)
        defer { inFlight.remove(endpoint.id) }

        if let existing = await existingMount(for: endpoint) {
            if await inspector.isResponsive(path: existing.on) {
                states[endpoint.id] = .mounted(path: existing.on)
                attempts[endpoint.id] = 0
                return
            }
            // Listed but dead. Clear it before remounting. A force-unmount that itself
            // fails is a mount failure, not something to paper over: reporting
            // `.mounted` while the dead mount is still attached would be the engine
            // lying about the one thing it exists to get right.
            states[endpoint.id] = .stale(path: existing.on)
            do {
                try await service.unmount(path: existing.on, force: true)
            } catch {
                fail(endpoint, with: MountFailure(reason: .mountpointBusy))
                return
            }
        }

        guard let password = await passwordProvider(endpoint) else {
            fail(endpoint, with: MountFailure(reason: .noCredential))
            return
        }

        states[endpoint.id] = .mounting
        do {
            let service = self.service
            let path = try await withTimeout(mountDeadline) {
                try await service.mount(endpoint: endpoint, password: password)
            }
            states[endpoint.id] = .mounted(path: path)
            attempts[endpoint.id] = 0
        } catch let failure as MountFailure {
            fail(endpoint, with: failure)
        } catch {
            fail(endpoint, with: MountFailure(reason: .unknown))
        }
    }

    private func existingMount(for endpoint: ShareEndpoint) async -> MountedVolume? {
        let identifier = endpoint.mountFromIdentifier
        return await inspector.mountedVolumes().first { $0.from == identifier }
    }

    private func fail(_ endpoint: ShareEndpoint, with failure: MountFailure) {
        states[endpoint.id] = .failed(failure)
        attempts[endpoint.id, default: 0] += 1
    }
}
