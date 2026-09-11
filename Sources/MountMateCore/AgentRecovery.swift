import Foundation

// When macOS's network-mount agent wedges, MountMate restarts it.
//
// NetAuthSysAgent can block indefinitely inside the SMB client's post-mount account
// lookup, waiting on an LSA reply the server never sends. Every NetFS mount queues
// behind it, so MountMate times out forever while the server is demonstrably up.
// Restarting the agent — launchd respawns it on demand — fixed it every time it was
// seen. What leaves the agent in that state is not known; this does not need it to be.

/// When a failed mount warrants restarting the agent. Pure, so tested directly.
public struct AgentRecoveryPolicy: Sendable, Equatable {
    /// Shared across every share: one agent serves them all.
    public let cooldown: Duration

    public init(cooldown: Duration) {
        self.cooldown = cooldown
    }

    /// Five minutes: recovers a share within a few minutes, and bounds a server that
    /// keeps wedging the agent to twelve restarts an hour, each one logged.
    public static let standard = AgentRecoveryPolicy(cooldown: .seconds(300))

    /// The two faces of a call stuck in the agent: the attempt that waited out its
    /// deadline, and the later ones refused because that call still holds the budget.
    /// Everything else is a real answer from somewhere, which a restart cannot change.
    public func isStuckAgentSignature(_ failure: MountFailure) -> Bool {
        failure.reason == .timedOut || failure.reason == .serverNotResponding
    }

    public func mayRestart(now: Date, lastRestart: Date?) -> Bool {
        guard let lastRestart else { return true }
        return now.timeIntervalSince(lastRestart) >= Double(cooldown.components.seconds)
    }
}

/// Whether the server behind an endpoint is answering at all.
public protocol ServerReachability: Sendable {
    func answers(_ endpoint: ShareEndpoint) async -> Bool
}

/// Restarts macOS's network-mount agent.
public protocol AgentResetter: Sendable {
    func restartNetworkMountAgent() async
}

/// Restarts the agent when a failure says it is stuck, and nothing else.
public actor AgentRecovery {
    private let policy: AgentRecoveryPolicy
    private let reachability: any ServerReachability
    private let resetter: any AgentResetter
    private let log: (any ActivityLog)?
    private let now: @Sendable () -> Date

    private var lastRestart: Date?
    /// Held across the awaits below. The engine and the Test button share this actor,
    /// and without it two failures arriving together would both pass the cooldown
    /// check and restart the agent twice — the second killing the fresh one.
    private var deciding = false

    public init(
        policy: AgentRecoveryPolicy = .standard,
        reachability: any ServerReachability,
        resetter: any AgentResetter,
        log: (any ActivityLog)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.reachability = reachability
        self.resetter = resetter
        self.log = log
        self.now = now
    }

    /// Restarts the agent if `failure` is its signature, the cooldown allows it, and
    /// the server is up. Returns whether it did.
    @discardableResult
    public func recover(after failure: MountFailure, mounting endpoint: ShareEndpoint) async -> Bool {
        // Cheapest first: a failure that is not the signature costs no network probe.
        guard policy.isStuckAgentSignature(failure),
              policy.mayRestart(now: now(), lastRestart: lastRestart),
              !deciding else { return false }
        deciding = true
        defer { deciding = false }

        // A server that does not answer is the network's problem, not the agent's.
        guard await reachability.answers(endpoint) else { return false }

        await resetter.restartNetworkMountAgent()
        lastRestart = now()
        await log?.append(ActivityEntry(
            timestamp: now(),
            category: .mount,
            share: endpoint.displayName,
            message: "restarted the network-mount agent, which was stuck"
        ))
        return true
    }
}

/// Gives both mount paths — the engine's attempts and Settings' Test button — the
/// chance to recover a stuck agent, without either of them knowing it exists.
///
/// The original failure is always rethrown unchanged. What follows a restart is
/// existing behaviour: backoff retries within seconds, the released call is verified
/// and cleaned up by the abandoned-attempt disposal, and the retry either adopts the
/// share that call mounted or mounts it fresh through the new agent.
public struct RecoveringMountService: MountService {
    private let inner: any MountService
    private let recovery: AgentRecovery

    public init(wrapping inner: any MountService, recovery: AgentRecovery) {
        self.inner = inner
        self.recovery = recovery
    }

    public func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        do {
            return try await inner.mount(endpoint: endpoint, password: password)
        } catch let failure as MountFailure {
            await recovery.recover(after: failure, mounting: endpoint)
            throw failure
        }
    }

    public func unmount(path: String, force: Bool) async throws {
        try await inner.unmount(path: path, force: force)
    }
}
