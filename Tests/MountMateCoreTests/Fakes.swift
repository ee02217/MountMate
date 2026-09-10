import Foundation
@testable import MountMateCore

/// Records calls and replays scripted outcomes.
actor FakeMountService: MountService {
    struct MountCall: Equatable {
        let endpointID: UUID
        let password: String
    }

    /// `force` is recorded, not discarded: spec §5.3 requires the stale-mount cleanup
    /// to be a *force* unmount, and a fake that only remembered the path made that
    /// requirement untestable.
    struct UnmountCall: Equatable {
        let path: String
        let force: Bool
    }

    private(set) var mountCalls: [MountCall] = []
    private(set) var unmountCalls: [UnmountCall] = []

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
        unmountCalls.append(UnmountCall(path: path, force: force))
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

/// A liveness probe that blocks until released, and counts how many times it was
/// actually entered. Stands in for a wedged hard mount, which cannot be manufactured
/// in a unit test.
final class HangingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries = 0
    private let gate = DispatchSemaphore(value: 0)

    var entries: Int {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func callAsFunction(_ path: String) -> Bool {
        lock.lock()
        _entries += 1
        lock.unlock()
        // Blocks with no suspension point, exactly like `statfs` on a wedged mount.
        gate.wait()
        return true
    }

    /// Lets any parked probe threads finish so the test process does not exit with
    /// threads still parked on the semaphore.
    func release(_ count: Int = 8) {
        for _ in 0..<count { gate.signal() }
    }
}
