import Testing
import Foundation
@testable import MountMateCore

@Test func aSuccessfulTestUnmountsWhatItMounted() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()

    let tester = ConnectionTester(service: service, inspector: inspector)
    let result = await tester.test(endpoint, password: "hunter2")

    #expect(result == .succeeded(path: "/Volumes/Fake"))
    // It created the mount, so it cleans it up: testing an unsaved share must not
    // leave a volume attached to a configuration that does not exist.
    let unmounts = await service.unmountCalls
    #expect(unmounts == [FakeMountService.UnmountCall(path: "/Volumes/Fake", force: false)])
}

@Test func testingAnAlreadyMountedShareLeavesItAlone() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()
    await inspector.setVolumes([
        MountedVolume(from: endpoint.mountFromIdentifier, on: "/Volumes/Multimedia")
    ])

    let tester = ConnectionTester(service: service, inspector: inspector)
    let result = await tester.test(endpoint, password: "hunter2")

    #expect(result == .alreadyMounted(path: "/Volumes/Multimedia"))
    // Never mounted, never unmounted — whatever is reading from it keeps reading.
    #expect(await service.mountCalls.isEmpty)
    #expect(await service.unmountCalls.isEmpty)
}

@Test func aFailedTestReportsTheRealReason() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    await service.setMountResult(.failure(MountFailure(reason: .authenticationFailed)))
    let endpoint = try makeStoreEndpoint()

    let tester = ConnectionTester(service: service, inspector: inspector)
    let result = await tester.test(endpoint, password: "wrong")

    #expect(result == .failed(MountFailure(reason: .authenticationFailed)))
    #expect(await service.unmountCalls.isEmpty)
}

@Test func testingWithNoPasswordReportsNoCredential() async throws {
    let service = FakeMountService()
    let inspector = FakeMountInspector()
    let endpoint = try makeStoreEndpoint()

    let tester = ConnectionTester(service: service, inspector: inspector)
    let result = await tester.test(endpoint, password: nil)

    #expect(result == .failed(MountFailure(reason: .noCredential)))
    #expect(await service.mountCalls.isEmpty)
}
