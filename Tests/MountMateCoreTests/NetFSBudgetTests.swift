import Testing
import Foundation
@testable import MountMateCore

/// The C call that parks in the kernel, stubbed. Counts entries and blocks until
/// released — a wedged SMB service cannot be manufactured in a unit test.
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

private func makeEndpoint(
    name: String = "Multimedia", host: String = "192.168.1.67"
) throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: name,
        url: URL(string: "smb://\(host)/\(name)")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

@Test func repeatedMountsAgainstAWedgedServerStopStrandingThreads() async throws {
    // The reported failure: with the NAS's SMB service wedged, every ~45s retry
    // parked another thread in NetFSMountURLSync — 7 of the app's 16 threads, growing
    // without bound. `MountEngine.inFlight` cannot prevent it: it releases in `defer`
    // the moment the deadline fires, which is exactly when the thread is stranded.
    let call = HangingMountCall()
    defer { call.release() }
    let service = NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: BlockingCallBudget(limit: 2),
        mountCall: { call($0, $1, $2) }
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

    #expect(call.entries == 2, "attempt \(call.entries) parked a thread past the budget")
    #expect(
        await engine.state(for: endpoint.id)
            == .failed(MountFailure(reason: .serverNotResponding))
    )
}

@Test func twoSharesOnOneWedgedServerShareItsThreadBudget() async throws {
    // The wedge is a property of the server, not the share, so the budget is keyed by
    // host: a second share on the same dead NAS must not buy a second allowance.
    let call = HangingMountCall()
    defer { call.release() }
    let service = NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: BlockingCallBudget(limit: 1),
        mountCall: { call($0, $1, $2) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(name: "Multimedia"), password: "hunter2")
    }
    await #expect(throws: MountFailure(reason: .serverNotResponding)) {
        try await service.mount(endpoint: try makeEndpoint(name: "Backups"), password: "hunter2")
    }

    #expect(call.entries == 1)
}

@Test func aDifferentServerKeepsItsOwnThreadBudget() async throws {
    // One dead NAS must not stop a healthy one from mounting.
    let call = HangingMountCall()
    defer { call.release() }
    let service = NetFSMountService(
        mountDeadline: .milliseconds(100),
        unmountDeadline: .milliseconds(100),
        budget: BlockingCallBudget(limit: 1),
        mountCall: { call($0, $1, $2) }
    )

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(host: "192.168.1.67"), password: "hunter2")
    }
    // The other server gets a thread of its own rather than inheriting the refusal.
    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await service.mount(endpoint: try makeEndpoint(host: "192.168.1.99"), password: "hunter2")
    }

    #expect(call.entries == 2)
}

@Test func aServerThatAnswersNeverExhaustsItsBudget() async throws {
    // Every successful mount must return its slot, however many times it is remounted.
    let budget = BlockingCallBudget(limit: 2)
    let service = NetFSMountService(
        mountDeadline: .seconds(5),
        unmountDeadline: .seconds(5),
        budget: budget,
        mountCall: { _, _, _ in
            NetFSMountService.MountOutcome(status: 0, firstPath: "/Volumes/Multimedia")
        }
    )
    let endpoint = try makeEndpoint()

    for _ in 0..<5 {
        #expect(try await service.mount(endpoint: endpoint, password: "hunter2") == "/Volumes/Multimedia")
    }

    #expect(budget.outstanding(for: "192.168.1.67") == 0)
}
