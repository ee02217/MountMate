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
    var unmountResult: Result<Void, MountFailure> = .success(())

    func setMountResult(_ result: Result<String, MountFailure>) { mountResult = result }
    func setMountDelay(_ delay: Duration) { mountDelay = delay }
    func setUnmountResult(_ result: Result<Void, MountFailure>) { unmountResult = result }

    func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        mountCalls.append(MountCall(endpointID: endpoint.id, password: password))
        if mountDelay > .zero { try await Task.sleep(for: mountDelay) }
        return try mountResult.get()
    }

    func unmount(path: String, force: Bool) async throws {
        unmountCalls.append(path)
        try unmountResult.get()
    }
}

/// A settable mount table.
actor FakeMountInspector: MountInspector {
    private var volumes: [MountedVolume] = []
    private var responsive: Set<String> = []

    func setVolumes(_ volumes: [MountedVolume]) { self.volumes = volumes }
    func setResponsive(_ paths: Set<String>) { self.responsive = paths }

    func mountedVolumes() async -> [MountedVolume] { volumes }
    func isResponsive(path: String) async -> Bool { responsive.contains(path) }
}
