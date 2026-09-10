import Testing
import Foundation
@testable import MountMateCore

private func makeEndpoint() -> ShareEndpoint {
    ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

private func makeEngine(
    service: FakeMountService,
    inspector: FakeMountInspector,
    password: String? = "hunter2",
    deadline: Duration = .seconds(45)
) -> MountEngine {
    MountEngine(
        service: service,
        inspector: inspector,
        backoff: .standard,
        mountDeadline: deadline,
        passwordProvider: { _ in password }
    )
}

@Test func mountsAnAbsentShare() async {
    let service = FakeMountService()
    await service.setMountResult(.success("/Volumes/Multimedia"))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
    #expect(await service.mountCalls.count == 1)
}

@Test func doesNothingWhenAlreadyMountedAndResponsive() async {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive(["/Volumes/Multimedia"])
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
    #expect(await service.mountCalls.isEmpty)   // must not remount a healthy share
}

@Test func remountsAShareThatIsListedButDead() async {
    let service = FakeMountService()
    await service.setMountResult(.success("/Volumes/Multimedia"))
    let inspector = FakeMountInspector()
    let endpoint = makeEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])
    await inspector.setResponsive([])           // listed, but does not answer
    let engine = makeEngine(service: service, inspector: inspector)

    await engine.ensureMounted(endpoint)

    #expect(await service.unmountCalls == ["/Volumes/Multimedia"])
    #expect(await service.mountCalls.count == 1)
    #expect(await engine.state(for: endpoint.id) == .mounted(path: "/Volumes/Multimedia"))
}

@Test func recordsFailureAndGrowsBackoff() async {
    let service = FakeMountService()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = makeEndpoint()

    await engine.ensureMounted(endpoint)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(5))

    await engine.ensureMounted(endpoint)
    #expect(await engine.retryDelay(for: endpoint.id) == .seconds(10))

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .hostUnreachable)))
}

@Test func resetBackoffClearsAttemptCounts() async {
    let service = FakeMountService()
    await service.setMountResult(.failure(MountFailure(reason: .hostUnreachable)))
    let engine = makeEngine(service: service, inspector: FakeMountInspector())
    let endpoint = makeEndpoint()

    await engine.ensureMounted(endpoint)
    await engine.ensureMounted(endpoint)
    await engine.resetBackoff()

    #expect(await engine.retryDelay(for: endpoint.id) == nil)
}

@Test func abandonsAMountThatExceedsTheDeadline() async {
    let service = FakeMountService()
    await service.setMountDelay(.seconds(10))
    let engine = makeEngine(
        service: service, inspector: FakeMountInspector(), deadline: .milliseconds(50)
    )
    let endpoint = makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .timedOut)))
}

@Test func failsClosedWhenNoCredentialIsAvailable() async {
    let service = FakeMountService()
    let engine = makeEngine(
        service: service, inspector: FakeMountInspector(), password: nil
    )
    let endpoint = makeEndpoint()

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .failed(MountFailure(reason: .noCredential)))
    #expect(await service.mountCalls.isEmpty)
}

@Test func skipsDisabledEndpoints() async {
    let service = FakeMountService()
    var endpoint = makeEndpoint()
    endpoint.enabled = false
    let engine = makeEngine(service: service, inspector: FakeMountInspector())

    await engine.ensureMounted(endpoint)

    #expect(await engine.state(for: endpoint.id) == .idle)
    #expect(await service.mountCalls.isEmpty)
}
