import Foundation

/// Owns all mount state. Deliberately does not sleep or schedule: it computes
/// `retryDelay(for:)` and lets the trigger layer decide when to call back. That keeps
/// the state machine deterministic under test — no fake clocks required.
public actor MountEngine {
    private let service: any MountService
    private let inspector: any MountInspector
    private let backoff: BackoffPolicy
    private let mountDeadline: Duration
    private let unmountDeadline: Duration
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
    /// Endpoint ids whose trigger arrived while an attempt was already running. The
    /// in-flight call honours it with one more pass before returning, so a trigger is
    /// coalesced rather than dropped. See `ensureMounted`.
    private var rerunRequested: Set<UUID> = []

    public init(
        service: any MountService,
        inspector: any MountInspector,
        backoff: BackoffPolicy = .standard,
        mountDeadline: Duration = .seconds(45),
        unmountDeadline: Duration = .seconds(20),
        passwordProvider: @escaping @Sendable (ShareEndpoint) async -> String?
    ) {
        self.service = service
        self.inspector = inspector
        self.backoff = backoff
        self.mountDeadline = mountDeadline
        self.unmountDeadline = unmountDeadline
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

    /// Brings `endpoint` to a mounted state if it is not already there.
    ///
    /// This is the engine's entire public surface for the trigger layer, so its
    /// guarantees are worth stating precisely.
    ///
    /// **What a return guarantees:** that the engine is no longer working on this
    /// endpoint. Read `state(for:)` for the outcome — returning is *not* a success
    /// signal, and the call may legitimately have done nothing at all (the endpoint was
    /// disabled, or was already mounted and responsive).
    ///
    /// **Concurrency.** One attempt runs per endpoint at a time. A call arriving while
    /// an attempt is in flight does not start a second attempt and does not wait for
    /// the running one; it returns immediately and is **coalesced**: the in-flight call
    /// makes one further pass before it returns. That matters because triggers carry
    /// information. The motivating case: an attempt is grinding against a dead network
    /// path, `NWPathMonitor` fires because Wi-Fi came back, and the trigger layer calls
    /// `resetBackoff()` and then `ensureMounted`. Without coalescing that trigger is
    /// discarded, the in-flight attempt then fails against the *old* path, and the
    /// engine settles into `.failed` with `retryDelay == nil` — "nothing to retry" —
    /// so nothing runs until the 5-minute backstop. With coalescing the new path gets
    /// its attempt.
    ///
    /// It is one further pass, not a loop: a fast trigger source must not be able to
    /// hold the engine in `ensureMounted` indefinitely. A pass that ended `.mounted`
    /// has already satisfied whatever the dropped trigger wanted, so it is not
    /// repeated.
    ///
    /// **Backoff.** Every failed pass — including `.noCredential`, which never touches
    /// the network — increments the attempt count, so `retryDelay(for:)` grows.
    ///
    /// **Cancellation.** If the enclosing task is cancelled the call returns without
    /// recording a failure or advancing backoff: shutting down is not a mount failure.
    public func ensureMounted(_ endpoint: ShareEndpoint) async {
        guard endpoint.enabled else {
            states[endpoint.id] = .idle
            return
        }

        // No `await` between the check and the insert: on an actor that makes the
        // pair atomic, so a concurrent call for the same endpoint records its request
        // and bails out instead of racing this one to `service.mount`.
        guard !inFlight.contains(endpoint.id) else {
            rerunRequested.insert(endpoint.id)
            return
        }
        inFlight.insert(endpoint.id)
        rerunRequested.remove(endpoint.id)
        defer {
            inFlight.remove(endpoint.id)
            rerunRequested.remove(endpoint.id)
        }

        await attempt(endpoint)

        // A trigger arrived mid-attempt. Honour it with one further pass, unless the
        // pass that just ran already ended mounted — in which case there is nothing
        // left for that trigger to ask for.
        if rerunRequested.remove(endpoint.id) != nil {
            if case .mounted = state(for: endpoint.id) { return }
            await attempt(endpoint)
        }
    }

    /// Detaches the endpoint at the user's request.
    ///
    /// Not forced: a force-unmount is for a wedged mount the engine found on its own,
    /// where the alternative is lying about `.mounted`. Here a person asked, so a
    /// refusal ("file in use") is information they should get rather than something
    /// to override on their behalf.
    ///
    /// The state becomes `.idle`, not `.failed`: nothing failed. The caller is
    /// expected to disable the endpoint as well — otherwise the next sweep simply
    /// mounts it again (spec §8).
    public func unmount(_ endpoint: ShareEndpoint) async throws {
        guard let existing = await mounts(for: endpoint).expected else {
            // Already detached. The desired end state, so not an error.
            states[endpoint.id] = .idle
            return
        }

        let service = self.service
        let path = existing.on
        try await withTimeout(unmountDeadline) {
            try await service.unmount(path: path, force: false)
        }

        states[endpoint.id] = .idle
        attempts[endpoint.id] = 0
    }

    private func attempt(_ endpoint: ShareEndpoint) async {
        // Strays first: when both a stray and a good mount exist, one pass then
        // reaches the right state rather than two.
        let partition = await mounts(for: endpoint)
        await clearStrays(partition.strays)

        if let existing = partition.expected {
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
                // Deadlined like the mount is. Force-unmounting a wedged mount is
                // exactly the call most likely to block, and without a bound here it
                // could hang before the mount deadline was ever reached — which, with
                // the `inFlight` guard above, would silently drop every later trigger
                // for this endpoint.
                let service = self.service
                let path = existing.on
                try await withTimeout(unmountDeadline) {
                    try await service.unmount(path: path, force: true)
                }
            } catch is CancellationError {
                return
            } catch let failure as MountFailure {
                // Report what actually happened. Rebuilding this as `.mountpointBusy`
                // discarded the real cause (host unreachable, timed out, …).
                fail(endpoint, with: failure)
                return
            } catch {
                fail(endpoint, with: MountFailure(reason: .unknown))
                return
            }
        }

        // Before the Keychain, not after. A blocked mountpoint is a certainty rather
        // than a guess, so there is no reason to reach for the credential (and, for a
        // locked Keychain, the authorization prompt behind it) on an attempt that
        // cannot succeed.
        let blockage = await obstruction(for: endpoint)
        if blockage != .clear {
            fail(endpoint, with: MountFailure(
                reason: .mountpointOccupied,
                obstruction: blockage,
                path: ExpectedMountpoint.path(for: endpoint)
            ))
            return
        }

        guard let password = await passwordProvider(endpoint) else {
            // Counts as an attempt on purpose: without the backoff growing, a trigger
            // layer facing a locked or empty Keychain would hot-loop the credential
            // provider (and, for a Keychain-backed provider, the authorization prompt
            // behind it) as fast as it can fire.
            fail(endpoint, with: MountFailure(reason: .noCredential))
            return
        }

        states[endpoint.id] = .mounting
        do {
            let service = self.service
            let path = try await withTimeout(mountDeadline) {
                try await service.mount(endpoint: endpoint, password: password)
            }
            // NetFS returns whatever mountpoint it chose. When the expected one is
            // occupied it silently picks `<name>-1`, and accepting that would leave
            // everything configured against the expected path broken while this
            // engine reported success (spec §9.1).
            guard ExpectedMountpoint.matches(path, for: endpoint) else {
                // `try?`: if detaching the stray mount also fails there is nothing
                // further to do here, and reporting the *original* problem — the
                // occupied mountpoint — is more useful than the cleanup's failure.
                let service = self.service
                try? await withTimeout(unmountDeadline) {
                    try await service.unmount(path: path, force: false)
                }
                fail(endpoint, with: MountFailure(reason: .mountpointOccupied))
                return
            }

            states[endpoint.id] = .mounted(path: path)
            attempts[endpoint.id] = 0
        } catch let failure as MountFailure {
            fail(endpoint, with: failure)
        } catch is CancellationError {
            // The enclosing task was cancelled — the app is shutting down, not failing
            // to mount. Recording `.failed` and advancing backoff would make an
            // orderly quit look like an outage.
            return
        } catch {
            fail(endpoint, with: MountFailure(reason: .unknown))
        }
    }

    /// What, if anything, is sitting on this endpoint's expected mountpoint.
    ///
    /// The mount table is consulted first: it is already in hand, costs no syscall,
    /// and cannot block. The filesystem is asked only when the table has no answer,
    /// which is what keeps this off any path that could be a wedged mount.
    private func obstruction(for endpoint: ShareEndpoint) async -> MountpointObstruction {
        let path = ExpectedMountpoint.path(for: endpoint)
        if let fromTable = MountpointObstruction.fromMountTable(
            expectedPath: path,
            volumes: await inspector.mountedVolumes(),
            ownIdentifier: endpoint.mountFromIdentifier
        ) {
            return fromTable
        }
        return MountpointObstruction.fromDirectory(
            await inspector.directoryState(at: path)
        )
    }

    private func mounts(for endpoint: ShareEndpoint) async -> EndpointMounts.Partition {
        EndpointMounts.partition(await inspector.mountedVolumes(), for: endpoint)
    }

    /// Detaches mounts of this endpoint that landed anywhere but the expected path.
    ///
    /// Best effort by design. A stray at `<name>-1` does not block the expected path,
    /// so one we cannot clear must not stop a mount that would otherwise work — the
    /// outcome is decided by the adopt and mount steps that follow. Not forced: these
    /// are wreckage, not wedged mounts, and forcing would reach past a refusal we have
    /// no reason to expect.
    private func clearStrays(_ strays: [MountedVolume]) async {
        let service = self.service
        for stray in strays {
            let path = stray.on
            try? await withTimeout(unmountDeadline) {
                try await service.unmount(path: path, force: false)
            }
        }
    }

    private func fail(_ endpoint: ShareEndpoint, with failure: MountFailure) {
        states[endpoint.id] = .failed(failure)
        attempts[endpoint.id, default: 0] += 1
    }
}
