import Testing
import Foundation
@testable import MountMateCore

private func makeEndpoint() throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

@Test func aMountAtTheWrongPathIsUndoneAndReported() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()

    // NetFS does this when /Volumes/Multimedia is already taken.
    await service.setMountResult(.success("/Volumes/Multimedia-1"))

    let engine = makeEngine(service: service, inspector: inspector)
    await engine.ensureMounted(endpoint)

    // Not reported as mounted — everything configured against the expected path
    // would otherwise be broken while the app claimed success.
    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .mountpointOccupied)))

    // And the stray mount is detached rather than left behind.
    let unmounts = await service.unmountCalls
    #expect(unmounts.contains(FakeMountService.UnmountCall(path: "/Volumes/Multimedia-1", force: false)))
}

@Test func aMountAtTheExpectedPathIsAccepted() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await service.setMountResult(.success("/Volumes/Multimedia"))

    let engine = makeEngine(service: service, inspector: inspector)
    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
    #expect(await service.unmountCalls.isEmpty)
}

/// An occupied mountpoint counts as a failure for backoff, so it retries later —
/// whatever is holding the path may go away.
@Test func anOccupiedMountpointAdvancesBackoff() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await service.setMountResult(.success("/Volumes/Multimedia-1"))

    let engine = makeEngine(service: service, inspector: inspector)
    await engine.ensureMounted(endpoint)

    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))
}

private func makeEngine(
    service: FakeMountService,
    inspector: FakeMountInspector,
    password: String? = "hunter2",
    deadline: Duration = .seconds(45),
    unmountDeadline: Duration = .seconds(20)
) -> MountEngine {
    MountEngine(
        service: service,
        inspector: inspector,
        backoff: .standard,
        mountDeadline: deadline,
        unmountDeadline: unmountDeadline,
        passwordProvider: { _ in password }
    )
}

@Test func mountsAnAbsentShare() async throws {
    let service = FakeMountService()
    await service.setMountResult(.success("/Volumes/Multimedia"))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
    #expect(await service.mountCalls.count == 1)
}

@Test func doesNothingWhenAlreadyMountedAndResponsive() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive(["/Volumes/Multimedia"])
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
    #expect(await service.mountCalls.isEmpty)   // must not remount a healthy share
}

@Test func remountsAShareThatIsListedButDead() async throws {
    let service = FakeMountService()
    await service.setMountResult(.success("/Volumes/Multimedia"))
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive([])           // listed, but does not answer
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    // Spec §5.3: the cleanup unmount must be forced. A plain unmount of a wedged
    // mount is precisely the call that will not return.
    #expect(await service.unmountCalls == [
        FakeMountService.UnmountCall(path: "/Volumes/Multimedia", force: true)
    ])
    #expect(await service.mountCalls.count == 1)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
}

@Test func recordsFailureAndGrowsBackoff() async throws {
    let service = FakeMountService()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    await engine.ensureMounted(endpoint)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))

    await engine.ensureMounted(endpoint)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(10))

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .hostUnreachable)))
}

@Test func resetBackoffClearsAttemptCounts() async throws {
    let service = FakeMountService()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    await engine.ensureMounted(endpoint)
    await engine.ensureMounted(endpoint)
    await engine.resetBackoff()

    #expect(await engine.retryDelay(for: endpoint.id) == nil)
}

@Test func abandonsAMountThatExceedsTheDeadline() async throws {
    let service = FakeMountService()
    await service.setMountDelay(.seconds(10))
    let engine = makeEngine(
        service: service, inspector: FakeMountInspector(), deadline: .milliseconds(50)
    )
    let endpoint = try makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .timedOut)))
}

@Test func failsClosedWhenNoCredentialIsAvailable() async throws {
    let service = FakeMountService()
    let engine = makeEngine(
        service: service, inspector: FakeMountInspector(), password: nil
    )
    let endpoint = try makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .noCredential)))
    #expect(await service.mountCalls.isEmpty)
    // Backoff must advance even though nothing was attempted, so a trigger layer
    // cannot hot-loop the credential provider.
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))
}

@Test func concurrentEnsureMountedCallsOnlyMountOnce() async throws {
    let service = FakeMountService()
    await service.setMountResult(.success("/Volumes/Multimedia"))
    await service.setMountDelay(.milliseconds(100))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    async let first: Void = engine.ensureMounted(endpoint)
    async let second: Void = engine.ensureMounted(endpoint)
    _ = await (first, second)

    // The dropped call is coalesced, but the pass that ran ended `.mounted`, so there
    // is nothing for the extra pass to do and the share is not mounted twice.
    #expect(await service.mountCalls.count == 1)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
}

@Test func aTriggerArrivingMidAttemptIsNotLost() async throws {
    // The motivating scenario: an attempt is grinding against a dead path when
    // NWPathMonitor fires because the network came back. Before coalescing, that
    // trigger was dropped, the in-flight attempt then failed against the old path,
    // and the engine sat in `.failed` until the 5-minute backstop.
    let service = FakeMountService()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    await service.setMountDelay(.milliseconds(300))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    async let inFlight: Void = engine.ensureMounted(endpoint)
    try await Task.sleep(for: .milliseconds(60))   // let the first attempt get going
    await engine.ensureMounted(endpoint)           // dropped from running, not lost
    await inFlight

    #expect(await service.mountCalls.count == 2)
}

@Test func failingForceUnmountFailsClosedWithoutRemounting() async throws {
    let service = FakeMountService()
    await service.setUnmountResult(.failure(MountFailure(reason: .mountpointBusy)))
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive([])           // listed, but does not answer
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .mountpointBusy)))
    #expect(await service.mountCalls.isEmpty)
    #expect(await engine.retryDelay(for: endpoint.id) != nil)
}

@Test func unmountFailureReasonReachesTheEngineIntact() async throws {
    // The engine used to rebuild every unmount failure as `.mountpointBusy`, which
    // told the UI the mountpoint was busy when the real cause was the server being
    // gone. Report what happened.
    let service = FakeMountService()
    await service.setUnmountResult(
        .failure(MountFailure(reason: .hostUnreachable, status: Int32(EHOSTDOWN)))
    )
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive([])
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    #expect(
        await engine.state(for: endpoint.id)
            == .failed(MountFailure(reason: .hostUnreachable, status: Int32(EHOSTDOWN)))
    )
}

@Test func aForceUnmountThatHangsHitsItsOwnDeadline() async throws {
    // The stale-mount cleanup used to have no deadline at all, so a wedged unmount
    // could block before the mount deadline was ever reached — and with the in-flight
    // guard, that silently discards every later trigger for the endpoint.
    let service = HangingUnmountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive([])
    let engine = MountEngine(
        service: service,
        inspector: inspector,
        backoff: .standard,
        mountDeadline: .seconds(45),
        unmountDeadline: .milliseconds(100),
        passwordProvider: { _ in "hunter2" }
    )

    let clock = ContinuousClock()
    let start = clock.now
    await engine.ensureMounted(endpoint)
    let elapsed = clock.now - start

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .timedOut)))
    #expect(elapsed < .seconds(2))
}

@Test func cancellationIsNotRecordedAsAMountFailure() async throws {
    // Quitting the app must not look like an outage: no `.failed`, no backoff.
    let service = FakeMountService()
    await service.setMountDelay(.seconds(30))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = try makeEndpoint()

    let task = Task { await engine.ensureMounted(endpoint) }
    try await Task.sleep(for: .milliseconds(80))
    task.cancel()
    await task.value

    #expect(await engine.state(for: endpoint.id) == .mounting)
    #expect(await engine.retryDelay(for: endpoint.id) == nil)
}

@Test func skipsDisabledEndpoints() async throws {
    let service = FakeMountService()
    var endpoint = try makeEndpoint()
    endpoint.enabled = false
    let engine = makeEngine(service: service, inspector: FakeMountInspector())

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .idle)
    #expect(await service.mountCalls.isEmpty)
}

/// A service whose unmount never returns, standing in for a wedged mountpoint.
private struct HangingUnmountService: MountService {
    func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        "/Volumes/Multimedia"
    }

    func unmount(path: String, force: Bool) async throws {
        // A blocking sleep on a dedicated thread: no suspension point, so cooperative
        // cancellation cannot touch it — exactly like `Darwin.unmount` on a wedged
        // mountpoint. Bounded at 3s only so the test process does not carry a thread
        // parked forever.
        _ = await runBlocking(timeout: .seconds(30)) {
            Thread.sleep(forTimeInterval: 3)
            return true
        }
    }
}
