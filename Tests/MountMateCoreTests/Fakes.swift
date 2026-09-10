import Foundation
@testable import MountMateCore

/// Records calls and replays scripted outcomes.
actor FakeMountService: MountService {
    struct MountCall: Equatable {
        let endpointID: UUID
        let password: String
    }

    private(set) var mountCalls: [MountCall] = []
    private(set) var unmountCalls: [String] = []

    var mountResult: Result<String, MountFailure> = .success("/Volumes/Fake")
    var mountDelay: Duration = .zero

    func setMountResult(_ result: Result<String, MountFailure>) { mountResult = result }
    func setMountDelay(_ delay: Duration) { mountDelay = delay }

    func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        mountCalls.append(MountCall(endpointID: endpoint.id, password: password))
        if mountDelay > .zero { try await Task.sleep(for: mountDelay) }
        return try mountResult.get()
    }

    func unmount(path: String, force: Bool) async throws {
        unmountCalls.append(path)
    }
}
