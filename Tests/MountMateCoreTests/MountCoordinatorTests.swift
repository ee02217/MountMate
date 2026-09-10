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
