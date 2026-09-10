import Testing
import Foundation
@testable import MountMateCore

@Test func onlyGenuineTransitionsResetBackoff() {
    #expect(TriggerEvent.wake.resetsBackoff)
    #expect(TriggerEvent.networkBecameSatisfied.resetsBackoff)

    #expect(!TriggerEvent.networkChanged.resetsBackoff)
    #expect(!TriggerEvent.launch.resetsBackoff)
    #expect(!TriggerEvent.backstop.resetsBackoff)
    #expect(!TriggerEvent.userRequested(nil).resetsBackoff)
}

@Test func fakeSourceDeliversYieldedEvents() async {
    let source = FakeTriggerSource()
    source.yield(.wake)
    source.yield(.backstop)
    source.finish()

    var received: [TriggerEvent] = []
    for await event in source.events { received.append(event) }

    #expect(received == [.wake, .backstop])
}

private func makeEndpoint(
    id: UUID = UUID(),
    name: String = "Multimedia",
    host: String = "192.168.1.67"
) throws -> ShareEndpoint {
    try ShareEndpoint(
        id: id,
        displayName: name,
        url: URL(string: "smb://\(host)/\(name)")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

private func makeEngine(
    service: FakeMountService,
    inspector: any MountInspector
) -> MountEngine {
    MountEngine(
        service: service,
        inspector: inspector,
        passwordProvider: { _ in "hunter2" }
    )
}

@Test func anEventMountsEveryEndpoint() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let first = try makeEndpoint(name: "Multimedia")
    let second = try makeEndpoint(name: "Backup")

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [first, second] },
        sources: []
    )
    await coordinator.handle(.backstop)

    let mounted = await service.mountCalls.map(\.endpointID)
    #expect(Set(mounted) == Set([first.id, second.id]))
}

@Test func aUserRequestForOneEndpointTouchesOnlyThatEndpoint() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let first = try makeEndpoint(name: "Multimedia")
    let second = try makeEndpoint(name: "Backup")

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [first, second] },
        sources: []
    )
    await coordinator.handle(.userRequested(second.id))

    let mounted = await service.mountCalls.map(\.endpointID)
    #expect(mounted == [second.id])
}

@Test func aGenuineReconnectClearsTheRetryLadder() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: FakeScheduler(limit: 0)
    )
    await coordinator.handle(.backstop)
    await coordinator.handle(.backstop)
    let grown = await engine.retryDelay(for: endpoint.id)
    #expect(grown == .seconds(10))

    // The reset lands, then this event's own failed attempt puts the count at 1.
    await coordinator.handle(.networkBecameSatisfied)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))

    await coordinator.stop()
}

@Test func anOrdinaryPathUpdateLeavesTheLadderAlone() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: FakeScheduler(limit: 0)
    )
    await coordinator.handle(.backstop)
    await coordinator.handle(.backstop)

    // No reset: this is the third failure, so the ladder keeps growing.
    await coordinator.handle(.networkChanged)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(20))

    await coordinator.stop()
}

/// Waits for a condition, failing the test rather than hanging if it never holds.
private func pollUntil(
    _ condition: @Sendable () async -> Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true within \(timeout)")
}

@Test func aFailedEndpointIsRetriedAfterItsBackoffDelay() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()
    let scheduler = FakeScheduler(limit: 1)

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: scheduler
    )
    await coordinator.handle(.backstop)

    // First attempt failed, so a retry is scheduled at the initial 5s and — because
    // the fake does not wait — runs immediately, producing a second mount call.
    try await pollUntil { await service.mountCalls.count == 2 }
    // Only the first: the retry's own failure schedules the next rung (10s) before
    // this line runs, so comparing the whole array is a race.
    #expect(await scheduler.requested.first == .seconds(5))

    await coordinator.stop()
}

@Test func aMountedEndpointSchedulesNoRetry() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()
    let scheduler = FakeScheduler(limit: 1)

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: scheduler
    )
    await coordinator.handle(.backstop)

    // Mounted means attempt count 0, so `retryDelay` is nil and nothing is scheduled.
    #expect(await scheduler.requested.isEmpty)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Fake"))

    await coordinator.stop()
}

@Test func startEmitsLaunchAndThenFollowsItsSources() async throws {
    let service = FakeMountService()
    let inspector = CountingMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()
    let source = FakeTriggerSource()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [source],
        scheduler: FakeScheduler(limit: 0)
    )
    await coordinator.start()

    // `.launch` alone mounts it once.
    try await pollUntil { await service.mountCalls.count == 1 }

    // Already mounted and responsive, so a later event re-probes instead of remounting.
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Fake")
    ])
    await inspector.setResponsive(["/Volumes/Fake"])
    source.yield(.backstop)

    try await pollUntil { await inspector.responsiveChecks >= 1 }
    #expect(await service.mountCalls.count == 1)

    await coordinator.stop()
}

@Test func stopEndsConsumption() async throws {
    let service = FakeMountService()
    let inspector = CountingMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()
    let source = FakeTriggerSource()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [source],
        scheduler: FakeScheduler(limit: 0)
    )
    await coordinator.start()
    try await pollUntil { await service.mountCalls.count == 1 }

    await coordinator.stop()
    source.yield(.backstop)

    // Nothing consumes the event now, so the count stays where it was.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await service.mountCalls.count == 1)
}

@Test func everyAttemptPublishesASnapshot() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: FakeScheduler(limit: 0)
    )

    let statuses = await coordinator.statuses
    let collector = Task { () -> [EndpointStatus]? in
        for await snapshot in statuses { return snapshot }
        return nil
    }

    await coordinator.handle(.backstop)

    let snapshot = try #require(await collector.value)
    #expect(snapshot.count == 1)
    #expect(snapshot.first?.displayName == "Multimedia")
    #expect(snapshot.first?.state == .mounted(path: "/Volumes/Fake"))
    #expect(snapshot.first?.enabled == true)

    await coordinator.stop()
}

@Test func aDisabledEndpointAppearsInTheSnapshotAsDisabled() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    // Bound to a `let` after mutating: a `var` cannot be captured by the @Sendable
    // endpointsProvider closure.
    var mutable = try makeEndpoint()
    mutable.enabled = false
    let endpoint = mutable

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: FakeScheduler(limit: 0)
    )

    let statuses = await coordinator.statuses
    let collector = Task { () -> [EndpointStatus]? in
        for await snapshot in statuses { return snapshot }
        return nil
    }

    await coordinator.handle(.backstop)

    let snapshot = try #require(await collector.value)
    // It must still be listed — a disabled share the user cannot see is a share they
    // cannot re-enable.
    #expect(snapshot.first?.enabled == false)
    #expect(snapshot.first?.state == .idle)
    #expect(await service.mountCalls.isEmpty)

    await coordinator.stop()
}

@Test func theCoordinatorLogsAChangeButNotARepeat() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let endpoint = try makeEndpoint()
    let log = InMemoryActivityLog()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [endpoint] },
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        log: log
    )

    await coordinator.handle(.backstop)
    let firstEntries = await log.entries
    let afterFirst = firstEntries.filter { $0.category == .mount }.count
    #expect(afterFirst == 1)

    // Already mounted and unchanged: the second sweep must add nothing.
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Fake")
    ])
    await inspector.setResponsive(["/Volumes/Fake"])
    await coordinator.handle(.backstop)

    let secondEntries = await log.entries
    #expect(secondEntries.filter { $0.category == .mount }.count == afterFirst)

    await coordinator.stop()
}

@Test func startAndStopAreLogged() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let engine = makeEngine(service: service, inspector: inspector)
    let log = InMemoryActivityLog()

    let coordinator = MountCoordinator(
        engine: engine,
        endpointsProvider: { [] },
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        log: log
    )
    await coordinator.start()
    try await pollUntil {
        let entries = await log.entries
        return entries.contains { $0.message == "started" }
    }

    await coordinator.stop()
    try await pollUntil {
        let entries = await log.entries
        return entries.contains { $0.message == "stopped" }
    }
}
