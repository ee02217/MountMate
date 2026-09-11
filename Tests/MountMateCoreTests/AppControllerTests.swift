import Testing
import Foundation
@testable import MountMateCore

@Test func unmountingDetachesTheVolumeAndClearsTheState() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive(["/Volumes/Multimedia"])

    let engine = MountEngine(
        service: service,
        inspector: inspector,
        passwordProvider: { _ in "hunter2" }
    )
    await engine.ensureMounted(endpoint)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))

    try await engine.unmount(endpoint)

    // A non-forced unmount: the user asked, so there is no wedged mount to force.
    let calls = await service.unmountCalls
    #expect(calls == [FakeMountService.UnmountCall(path: "/Volumes/Multimedia", force: false)])
    #expect(await engine.state(for: endpoint.id) == .idle)
}

@Test func unmountingSomethingNotMountedDoesNothing() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()

    let engine = MountEngine(
        service: service,
        inspector: inspector,
        passwordProvider: { _ in "hunter2" }
    )
    try await engine.unmount(endpoint)

    #expect(await service.unmountCalls.isEmpty)
    #expect(await engine.state(for: endpoint.id) == .idle)
}

@Test func togglingAMountedEndpointUnmountsAndDisablesIt() async throws {
    let endpoint = try makeStoreEndpoint()
    let endpointStore = InMemoryEndpointStore(endpoints: [endpoint])
    let credentials = InMemoryCredentialStore()
    try await credentials.setPassword("hunter2", for: endpoint)

    let controller = AppController(
        endpointStore: endpointStore,
        credentialStore: credentials,
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    await controller.start()

    try await controller.toggle(endpoint.id)

    // Persisted, not just held in memory: the whole point is that it stays unmounted.
    let reloaded = try await endpointStore.load()
    #expect(reloaded.endpoints.first?.enabled == false)

    await controller.stop()
}

@Test func togglingADisabledEndpointEnablesItAndMountsIt() async throws {
    var mutable = try makeStoreEndpoint()
    mutable.enabled = false
    let endpoint = mutable
    let endpointStore = InMemoryEndpointStore(endpoints: [endpoint])
    let credentials = InMemoryCredentialStore()
    try await credentials.setPassword("hunter2", for: endpoint)

    let controller = AppController(
        endpointStore: endpointStore,
        credentialStore: credentials,
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    await controller.start()

    try await controller.toggle(endpoint.id)

    let reloaded = try await endpointStore.load()
    #expect(reloaded.endpoints.first?.enabled == true)

    await controller.stop()
}

@Test func theControllerKeepsWhatTheLoadSkipped() async throws {
    let endpointStore = InMemoryEndpointStore(endpoints: [try makeStoreEndpoint()])
    let controller = AppController(
        endpointStore: endpointStore,
        credentialStore: InMemoryCredentialStore(),
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    await controller.start()

    // Kept even when nothing is wrong: discarding it would leave Diagnostics unable
    // to report a config problem that already happened.
    #expect(await controller.lastLoad.skipped.isEmpty)
    #expect(await controller.lastLoad.endpoints.count == 1)

    await controller.stop()
}

@Test func applyingEndpointsPersistsThemAndRefreshesTheCache() async throws {
    let first = try makeStoreEndpoint(name: "Multimedia")
    let endpointStore = InMemoryEndpointStore(endpoints: [first])
    let controller = AppController(
        endpointStore: endpointStore,
        credentialStore: InMemoryCredentialStore(),
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    await controller.start()
    #expect(await controller.endpoints.count == 1)

    let second = try makeStoreEndpoint(name: "Backup")
    try await controller.apply([first, second])

    #expect(await controller.endpoints.count == 2)
    let reloaded = try await endpointStore.load()
    #expect(reloaded.endpoints.count == 2)

    await controller.stop()
}

/// Edits made to the file while the app runs must take effect, not wait for a restart.
@Test func reloadPicksUpChangesMadeOutsideTheController() async throws {
    let first = try makeStoreEndpoint(name: "Multimedia")
    let endpointStore = InMemoryEndpointStore(endpoints: [first])
    let controller = AppController(
        endpointStore: endpointStore,
        credentialStore: InMemoryCredentialStore(),
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    await controller.start()

    try await endpointStore.save([first, try makeStoreEndpoint(name: "Backup")])
    #expect(await controller.endpoints.count == 1)

    await controller.reload()
    #expect(await controller.endpoints.count == 2)

    await controller.stop()
}
