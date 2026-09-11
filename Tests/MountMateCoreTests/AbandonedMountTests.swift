import Testing
import Foundation
@testable import MountMateCore

/// A mount call that returns *after* its deadline has already released the caller —
/// the case the field failure turned on. NetFS was still working the whole time; when
/// NetAuthSysAgent was restarted every parked call completed at once, each landing on
/// the next free path.
private final class LateMountCall: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let path: String?
    private let status: Int32

    init(landsAt path: String?, status: Int32 = 0) {
        self.path = path
        self.status = status
    }

    func callAsFunction(
        _ endpoint: ShareEndpoint, _ password: String, _ directory: URL
    ) -> NetFSMountService.MountOutcome {
        gate.wait()
        return NetFSMountService.MountOutcome(status: status, firstPath: path)
    }

    /// Lets the parked call complete, as restarting NetAuthSysAgent did.
    func complete() { gate.signal() }
}

/// Records the unmounts the service performs, including those made from an abandoned
/// worker thread after the caller is long gone.
private final class RecordedUnmounts: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths
    }

    func callAsFunction(_ path: String, _ flags: Int32) -> NetFSMountService.UnmountOutcome {
        lock.lock(); _paths.append(path); lock.unlock()
        return NetFSMountService.UnmountOutcome(succeeded: true, errorNumber: 0)
    }

    /// Polls rather than sleeping a fixed interval: the cleanup happens on a thread
    /// nobody can await.
    func waitForUnmount(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if !paths.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func makeEndpoint(name: String = "Multimedia") throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: name,
        url: URL(string: "smb://192.0.2.10/\(name)")!,
        username: "nasuser",
        mountPolicy: .volumes
    )
}

private func makeService(
    mountCall: @escaping NetFSMountService.BlockingMountCall,
    unmountCall: @escaping NetFSMountService.BlockingUnmountCall,
    budget: BlockingCallBudget = BlockingCallBudget(limit: 1)
) -> NetFSMountService {
    NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: budget,
        mountCall: mountCall,
        unmountCall: unmountCall
    )
}

@Test func anAbandonedAttemptUnmountsTheStrayMountItEventuallyCreates() async throws {
    // The reported damage: seven abandoned attempts completed at once when
    // NetAuthSysAgent was restarted, each landing on the next free path, leaving
    // Multimedia-1 … Multimedia-6 behind. The mountpoint guard never saw them,
    // because a timed-out attempt returns its path to nobody.
    let call = LateMountCall(landsAt: "/Volumes/Multimedia-1")
    let unmounts = RecordedUnmounts()
    let service = makeService(
        mountCall: { call($0, $1, $2) }, unmountCall: { unmounts($0, $1) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(), password: "hunter2")
    }

    call.complete()                 // the server unwedges; the parked call returns
    await unmounts.waitForUnmount()

    #expect(unmounts.paths == ["/Volumes/Multimedia-1"])
}

@Test func anAbandonedAttemptThatLandsCorrectlyLeavesItsMountAlone() async throws {
    // A late attempt that reached the *expected* path did the job we wanted. The next
    // sweep finds it in the mount table and adopts it, so tearing it down would throw
    // away a good mount and guarantee another attempt.
    let call = LateMountCall(landsAt: "/Volumes/Multimedia")
    let unmounts = RecordedUnmounts()
    let service = makeService(
        mountCall: { call($0, $1, $2) }, unmountCall: { unmounts($0, $1) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(), password: "hunter2")
    }

    call.complete()
    try await Task.sleep(for: .milliseconds(300))

    #expect(unmounts.paths.isEmpty)
}

@Test func anAbandonedAttemptThatMountedNothingUnmountsNothing() async throws {
    // A late *failure* has no mount to dispose of. Unmounting on a non-zero status
    // would be acting on a path NetFS never returned.
    let call = LateMountCall(landsAt: nil, status: Int32(ETIMEDOUT))
    let unmounts = RecordedUnmounts()
    let service = makeService(
        mountCall: { call($0, $1, $2) }, unmountCall: { unmounts($0, $1) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(), password: "hunter2")
    }

    call.complete()
    try await Task.sleep(for: .milliseconds(300))

    #expect(unmounts.paths.isEmpty)
}

@Test func aResultDeliveredToTheCallerIsNotAlsoDisposedOf() async throws {
    // Exactly one of the two owns the outcome. The caller got this stray path, so
    // `MountEngine` will verify and unmount it; the service must not race that.
    let unmounts = RecordedUnmounts()
    let service = NetFSMountService(
        mountDeadline: .seconds(5),
        unmountDeadline: .seconds(5),
        budget: BlockingCallBudget(limit: 1),
        mountCall: { _, _, _ in
            NetFSMountService.MountOutcome(status: 0, firstPath: "/Volumes/Multimedia-1")
        },
        unmountCall: { unmounts($0, $1) }
    )

    let path = try await service.mount(endpoint: try makeEndpoint(), password: "hunter2")

    #expect(path == "/Volumes/Multimedia-1")
    #expect(unmounts.paths.isEmpty)
}

@Test func aSecondAttemptIsRefusedWhileTheFirstIsStillALiveMountRequest() async throws {
    // The crux. An outstanding attempt is not a stalled one: NetFS is still working
    // and will eventually mount. Starting a second request is what produced two
    // mounts at two paths, so one live request per share is the cap.
    let call = LateMountCall(landsAt: "/Volumes/Multimedia")
    let unmounts = RecordedUnmounts()
    let service = makeService(
        mountCall: { call($0, $1, $2) }, unmountCall: { unmounts($0, $1) }
    )
    let endpoint = try makeEndpoint()

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: endpoint, password: "hunter2")
    }
    await #expect(throws: MountFailure(reason: .serverNotResponding)) {
        try await service.mount(endpoint: endpoint, password: "hunter2")
    }

    call.complete()
}

@Test func adifferentShareIsNotBlockedByAnotherSharesOutstandingRequest() async throws {
    // The hazard is two live requests for the *same* share racing for one path. Two
    // shares land at different paths and cannot collide, so one must not refuse the
    // other even on the same wedged server.
    let call = LateMountCall(landsAt: "/Volumes/Multimedia")
    let unmounts = RecordedUnmounts()
    let service = makeService(
        mountCall: { call($0, $1, $2) }, unmountCall: { unmounts($0, $1) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(name: "Multimedia"), password: "hunter2")
    }
    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(name: "Backups"), password: "hunter2")
    }

    call.complete()
    call.complete()
}
