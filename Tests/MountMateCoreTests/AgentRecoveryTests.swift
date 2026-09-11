import Testing
import Foundation
@testable import MountMateCore

// NetAuthSysAgent wedged three times on 2026-09-10 and -11, stuck in the SMB client's
// account lookup with the NAS answering on 445 throughout. Restarting it fixed every
// one. These tests pin down exactly when MountMate does that on its own.

// MARK: - Policy

@Test func aTimeoutIsTheSignatureOfAStuckAgent() {
    #expect(AgentRecoveryPolicy.standard.isStuckAgentSignature(MountFailure(reason: .timedOut)))
}

/// After the first timeout the parked call holds the budget, so every later attempt is
/// refused with `.serverNotResponding` until the agent dies. Same stuck agent.
@Test func aRefusedAttemptBehindAParkedCallIsTheSameSignature() {
    #expect(AgentRecoveryPolicy.standard.isStuckAgentSignature(MountFailure(reason: .serverNotResponding)))
}

/// Real answers from somewhere. Restarting the agent would change none of them.
@Test func otherFailuresAreNotTheSignature() {
    let policy = AgentRecoveryPolicy.standard
    for reason: MountFailureReason in [
        .authenticationFailed, .hostUnreachable, .shareNotFound, .mountpointBusy,
        .mountpointOccupied, .noCredential, .unknown,
    ] {
        #expect(!policy.isStuckAgentSignature(MountFailure(reason: reason)))
    }
}

@Test func theFirstRestartIsAlwaysAllowed() {
    #expect(AgentRecoveryPolicy.standard.mayRestart(now: Date(), lastRestart: nil))
}

@Test func aSecondRestartWaitsOutTheCooldown() {
    let policy = AgentRecoveryPolicy(cooldown: .seconds(300))
    let last = Date(timeIntervalSince1970: 1_000)
    #expect(!policy.mayRestart(now: last.addingTimeInterval(299), lastRestart: last))
    #expect(policy.mayRestart(now: last.addingTimeInterval(300), lastRestart: last))
}

// MARK: - Recovery

private actor FakeReachability: ServerReachability {
    var answer: Bool
    var delay: Duration = .zero
    private(set) var asked = 0
    init(answer: Bool) { self.answer = answer }
    func setDelay(_ delay: Duration) { self.delay = delay }
    func answers(_ endpoint: ShareEndpoint) async -> Bool {
        asked += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return answer
    }
}

private actor FakeResetter: AgentResetter {
    private(set) var restarts = 0
    func restartNetworkMountAgent() async { restarts += 1 }
}

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private func makeRecovery(
    reachable: Bool = true,
    clock: ManualClock = ManualClock(),
    log: InMemoryActivityLog? = nil
) -> (AgentRecovery, FakeReachability, FakeResetter) {
    let reachability = FakeReachability(answer: reachable)
    let resetter = FakeResetter()
    let recovery = AgentRecovery(
        reachability: reachability, resetter: resetter, log: log, now: { clock.now }
    )
    return (recovery, reachability, resetter)
}

@Test func aTimeoutAgainstAReachableServerRestartsTheAgent() async throws {
    let (recovery, _, resetter) = makeRecovery()
    let restarted = await recovery.recover(
        after: MountFailure(reason: .timedOut), mounting: try makeStoreEndpoint()
    )
    #expect(restarted)
    #expect(await resetter.restarts == 1)
}

/// An unreachable server is the network's problem; the agent is not to blame.
@Test func anUnreachableServerLeavesTheAgentAlone() async throws {
    let (recovery, _, resetter) = makeRecovery(reachable: false)
    let restarted = await recovery.recover(
        after: MountFailure(reason: .timedOut), mounting: try makeStoreEndpoint()
    )
    #expect(!restarted)
    #expect(await resetter.restarts == 0)
}

/// Cheap checks first: a failure that is not the signature must not cost a network probe.
@Test func aNonSignatureFailureNeverProbesTheServer() async throws {
    let (recovery, reachability, resetter) = makeRecovery()
    await recovery.recover(
        after: MountFailure(reason: .authenticationFailed), mounting: try makeStoreEndpoint()
    )
    #expect(await reachability.asked == 0)
    #expect(await resetter.restarts == 0)
}

@Test func theCooldownHoldsAcrossCallsAndThenLifts() async throws {
    let clock = ManualClock()
    let (recovery, _, resetter) = makeRecovery(clock: clock)
    let endpoint = try makeStoreEndpoint()

    await recovery.recover(after: MountFailure(reason: .timedOut), mounting: endpoint)
    clock.advance(by: 60)
    await recovery.recover(after: MountFailure(reason: .serverNotResponding), mounting: endpoint)
    #expect(await resetter.restarts == 1)

    clock.advance(by: 300)
    await recovery.recover(after: MountFailure(reason: .timedOut), mounting: endpoint)
    #expect(await resetter.restarts == 2)
}

/// The engine and the Test button share one recovery. Two failures arriving together
/// must not restart the agent twice — the second would kill the fresh one.
@Test func concurrentFailuresRestartTheAgentOnce() async throws {
    let (recovery, reachability, resetter) = makeRecovery()
    await reachability.setDelay(.milliseconds(50))
    let endpoint = try makeStoreEndpoint()

    async let first = recovery.recover(after: MountFailure(reason: .timedOut), mounting: endpoint)
    async let second = recovery.recover(after: MountFailure(reason: .timedOut), mounting: endpoint)
    _ = await (first, second)

    #expect(await resetter.restarts == 1)
}

/// Silence in the log must still mean nothing happened.
@Test func aRestartIsLoggedAgainstTheShareThatRevealedIt() async throws {
    let log = InMemoryActivityLog()
    let (recovery, _, _) = makeRecovery(log: log)
    await recovery.recover(
        after: MountFailure(reason: .timedOut), mounting: try makeStoreEndpoint(name: "Multimedia")
    )
    let entries = await log.entries
    #expect(entries.count == 1)
    #expect(entries.first?.category == .mount)
    #expect(entries.first?.share == "Multimedia")
    #expect(entries.first?.message.hasPrefix("restarted the network-mount agent") == true)
}

// MARK: - Decorator

@Test func theDecoratorRethrowsTheOriginalFailureAfterRecovering() async throws {
    let inner = FakeMountService()
    await inner.setMountResult(.failure(MountFailure(reason: .timedOut, status: 60)))
    let (recovery, _, resetter) = makeRecovery()
    let service = RecoveringMountService(wrapping: inner, recovery: recovery)

    await #expect(throws: MountFailure(reason: .timedOut, status: 60)) {
        try await service.mount(endpoint: try makeStoreEndpoint(), password: "p")
    }
    #expect(await resetter.restarts == 1)
}

@Test func theDecoratorNeverActsOnSuccess() async throws {
    let inner = FakeMountService()
    let (recovery, reachability, resetter) = makeRecovery()
    let service = RecoveringMountService(wrapping: inner, recovery: recovery)

    let path = try await service.mount(endpoint: try makeStoreEndpoint(), password: "p")
    #expect(path == "/Volumes/Multimedia")
    #expect(await reachability.asked == 0)
    #expect(await resetter.restarts == 0)
}

@Test func theDecoratorPassesUnmountsStraightThrough() async throws {
    let inner = FakeMountService()
    let (recovery, _, _) = makeRecovery()
    let service = RecoveringMountService(wrapping: inner, recovery: recovery)

    try await service.unmount(path: "/Volumes/Multimedia", force: true)
    #expect(await inner.unmountCalls == [.init(path: "/Volumes/Multimedia", force: true)])
}

// MARK: - Real adapters (no NAS required)

@Test func smbAndAfpProbeTheirOwnPorts() throws {
    #expect(TCPReachability.port(for: try makeStoreEndpoint()) == 445)
}

/// Nothing listens on port 1 of the loopback interface, so the connection is refused.
/// Refused must read as "not answering", and promptly — not after the full timeout.
@Test func aRefusedConnectionIsNotAnAnswer() async throws {
    let endpoint = try ShareEndpoint(
        displayName: "Loopback",
        url: #require(URL(string: "smb://127.0.0.1:1/Nothing")),
        username: "nobody",
        mountPolicy: .volumes
    )
    let started = ContinuousClock.now
    #expect(await TCPReachability(timeout: .seconds(3)).answers(endpoint) == false)
    #expect(ContinuousClock.now - started < .seconds(3))
}

// MARK: - The race the live test exposed

/// Blocks the way NetFS does — on a thread, ignoring cancellation — then reports the
/// inner deadline.
private struct NonCooperativeTimingOutService: MountService {
    let blockFor: TimeInterval
    func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        _ = await runBlocking(timeout: .seconds(10)) { Thread.sleep(forTimeInterval: blockFor) }
        throw MountFailure(reason: .timedOut)
    }
    func unmount(path: String, force: Bool) async throws {}
}

/// Live, 2026-09-11: the engine's own 45s deadline and NetFS's inner one race. When
/// the engine's wins, it abandons and cancels the body the decorator runs in — and the
/// first stuck attempt then produced no restart. Recovery must not depend on which
/// deadline fires first.
@Test func recoveryStillRunsWhenTheCallersDeadlineWinsTheRace() async throws {
    let (recovery, _, resetter) = makeRecovery()
    let service = RecoveringMountService(
        wrapping: NonCooperativeTimingOutService(blockFor: 0.3), recovery: recovery
    )
    let endpoint = try makeStoreEndpoint()

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await withTimeout(.milliseconds(100)) {
            try await service.mount(endpoint: endpoint, password: "p")
        }
    }
    // The abandoned body finishes on its own, ~200ms later.
    try await Task.sleep(for: .milliseconds(600))
    #expect(await resetter.restarts == 1)
}
