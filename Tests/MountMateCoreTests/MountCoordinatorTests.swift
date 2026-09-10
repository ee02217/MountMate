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
        sources: []
    )
    await coordinator.handle(.backstop)
    await coordinator.handle(.backstop)
    let grown = await engine.retryDelay(for: endpoint.id)
    #expect(grown == .seconds(10))

    // The reset lands, then this event's own failed attempt puts the count at 1.
    await coordinator.handle(.networkBecameSatisfied)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))
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
        sources: []
    )
    await coordinator.handle(.backstop)
    await coordinator.handle(.backstop)

    // No reset: this is the third failure, so the ladder keeps growing.
    await coordinator.handle(.networkChanged)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(20))
}
