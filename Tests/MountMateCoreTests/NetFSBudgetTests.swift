import Testing
import Foundation
@testable import MountMateCore

/// A mount call that parks in the kernel until released, counting entries. A wedged
/// SMB service cannot be manufactured in a unit test.
private final class HangingMountCall: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entries = 0

    var entries: Int {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func callAsFunction(
        _ endpoint: ShareEndpoint, _ password: String, _ directory: URL
    ) -> NetFSMountService.MountOutcome {
        lock.lock(); _entries += 1; lock.unlock()
        gate.wait()
        return NetFSMountService.MountOutcome(status: 0, firstPath: "/Volumes/Multimedia")
    }

    func release(_ count: Int = 8) {
        for _ in 0..<count { gate.signal() }
    }
}

private let noopUnmount: NetFSMountService.BlockingUnmountCall = { _, _ in
    NetFSMountService.UnmountOutcome(succeeded: true, errorNumber: 0)
}

private func makeEndpoint(
    name: String = "Multimedia", host: String = "192.0.2.10"
) throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: name,
        url: URL(string: "smb://\(host)/\(name)")!,
        username: "nasuser",
        mountPolicy: .volumes
    )
}

@Test func retryingAWedgedShareNeverStartsASecondLiveMountRequest() async throws {
    // The reported failure end to end. With the NAS's SMB service wedged, the retry
    // ladder drove an attempt roughly every 45s and each one parked another thread —
    // 7 of the app's 16. Those were not idle threads but live mount requests, and
    // when NetAuthSysAgent was restarted all seven completed and landed on seven
    // different paths.
    //
    // `MountEngine.inFlight` cannot prevent this: it tracks the *awaited* call and
    // releases in `defer`, which runs the instant the deadline fires — exactly when
    // the request becomes abandoned-but-live. Its lifetime ends where the leak begins,
    // and retries are sequential anyway, so it is never consulted.
    let call = HangingMountCall()
    defer { call.release() }
    let service = NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: BlockingCallBudget(limit: 1),
        mountCall: { call($0, $1, $2) },
        unmountCall: noopUnmount
    )
    let endpoint = try makeEndpoint()
    let engine = MountEngine(
        service: service,
        inspector: FakeMountInspector(),
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        passwordProvider: { _ in "hunter2" }
    )

    for _ in 0..<6 {
        await engine.ensureMounted(endpoint)
    }

    #expect(call.entries == 1, "\(call.entries) live mount requests were outstanding at once")
    #expect(
        await engine.state(for: endpoint.id)
            == .failed(MountFailure(reason: .serverNotResponding))
    )
}

@Test func aDifferentServerKeepsItsOwnAllowance() async throws {
    // One dead NAS must not stop a healthy one from mounting.
    let call = HangingMountCall()
    defer { call.release() }
    let service = NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: BlockingCallBudget(limit: 1),
        mountCall: { call($0, $1, $2) },
        unmountCall: noopUnmount
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(host: "192.0.2.10"), password: "hunter2")
    }
    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(host: "192.0.2.99"), password: "hunter2")
    }

    #expect(call.entries == 2)
}

@Test func aServerThatAnswersNeverExhaustsItsAllowance() async throws {
    // Every completed mount returns its slot, however many times it is remounted.
    let budget = BlockingCallBudget(limit: 1)
    let endpoint = try makeEndpoint()
    let service = NetFSMountService(
        mountDeadline: .seconds(5),
        unmountDeadline: .seconds(5),
        budget: budget,
        mountCall: { _, _, _ in
            NetFSMountService.MountOutcome(status: 0, firstPath: "/Volumes/Multimedia")
        },
        unmountCall: noopUnmount
    )

    for _ in 0..<5 {
        #expect(try await service.mount(endpoint: endpoint, password: "hunter2") == "/Volumes/Multimedia")
    }

    #expect(budget.outstanding(for: NetFSMountService.budgetKey(for: endpoint)) == 0)
}
