import Testing
import Foundation
@testable import MountMateCore

@Test func unmountingDetachesTheVolumeAndClearsTheState() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Fake")
    ])
    await inspector.setResponsive(["/Volumes/Fake"])

    let engine = MountEngine(
        service: service,
        inspector: inspector,
        passwordProvider: { _ in "hunter2" }
    )
    await engine.ensureMounted(endpoint)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Fake"))

    try await engine.unmount(endpoint)

    // A non-forced unmount: the user asked, so there is no wedged mount to force.
    let calls = await service.unmountCalls
    #expect(calls == [FakeMountService.UnmountCall(path: "/Volumes/Fake", force: false)])
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
