import Testing
import Foundation
@testable import MountMateCore

@Test func budgetGrantsUpToItsLimitAndThenRefuses() {
    let budget = BlockingCallBudget(limit: 3)

    #expect(budget.claim("nas") == true)
    #expect(budget.claim("nas") == true)
    #expect(budget.claim("nas") == true)
    #expect(budget.claim("nas") == false)
}

@Test func releasingAStrandReopensItsSlot() {
    let budget = BlockingCallBudget(limit: 1)

    #expect(budget.claim("nas") == true)
    #expect(budget.claim("nas") == false)

    budget.release("nas")

    #expect(budget.claim("nas") == true)
}

@Test func oneWedgedServerDoesNotSpendAnotherServersBudget() {
    // A dead NAS must not stop a healthy one from mounting.
    let budget = BlockingCallBudget(limit: 1)

    #expect(budget.claim("dead-nas") == true)
    #expect(budget.claim("dead-nas") == false)
    #expect(budget.claim("healthy-nas") == true)
}

@Test func releasingAKeyThatHoldsNothingIsHarmless() {
    // The release runs on the abandoned worker thread, so it must tolerate being
    // reached in states the caller can no longer reason about.
    let budget = BlockingCallBudget(limit: 1)

    budget.release("nas")

    #expect(budget.outstanding(for: "nas") == 0)
    #expect(budget.claim("nas") == true)
}

// MARK: - The primitive that spends the budget

/// A body that blocks with no suspension point until released, exactly like
/// `NetFSMountURLSync` against a wedged SMB service, and counts how many times it was
/// actually entered. A refusal that still ran the body would strand a thread anyway,
/// so "was it entered" is the assertion that matters.
private final class GatedBody: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entries = 0

    var entries: Int {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func callAsFunction() -> Bool {
        lock.lock(); _entries += 1; lock.unlock()
        gate.wait()
        return true
    }

    /// Lets parked bodies finish so the test process does not exit holding threads.
    func release(_ count: Int = 8) {
        for _ in 0..<count { gate.signal() }
    }
}

@Test func aCallThatFinishesInTimeReturnsItsSlot() async throws {
    // A healthy server must never exhaust its budget, however many times it is mounted.
    let budget = BlockingCallBudget(limit: 2)

    for _ in 0..<5 {
        let value = try await withBoundedBlockingTimeout(
            .seconds(5), key: "nas", budget: budget
        ) { 7 }
        #expect(value == 7)
    }

    #expect(budget.outstanding(for: "nas") == 0)
}

@Test func anAttemptPastTheLimitIsRefusedWithoutStrandingAnotherThread() async throws {
    // The reported bug: every attempt against a wedged server parked another thread.
    let body = GatedBody()
    let budget = BlockingCallBudget(limit: 2)
    defer { body.release() }

    for _ in 0..<2 {
        await #expect(throws: MountFailure(reason: .timedOut)) {
            try await withBoundedBlockingTimeout(
                .milliseconds(100), key: "nas", budget: budget, { body() }
            )
        }
    }
    #expect(body.entries == 2)

    // The third attempt must not cost a thread, and must say why.
    await #expect(throws: MountFailure(reason: .serverNotResponding)) {
        try await withBoundedBlockingTimeout(
            .milliseconds(100), key: "nas", budget: budget, { body() }
        )
    }
    #expect(body.entries == 2, "the refused attempt still ran the blocking body")
}

@Test func aStrandThatFinallyReturnsReopensTheServerForAttempts() async throws {
    // Recovery is automatic: whatever unwedges the server returns the parked call.
    let body = GatedBody()
    let budget = BlockingCallBudget(limit: 1)

    await #expect(throws: MountFailure(reason: .timedOut)) {
        try await withBoundedBlockingTimeout(
            .milliseconds(100), key: "nas", budget: budget, { body() }
        )
    }
    await #expect(throws: MountFailure(reason: .serverNotResponding)) {
        try await withBoundedBlockingTimeout(
            .milliseconds(100), key: "nas", budget: budget, { body() }
        )
    }

    body.release()                                  // the parked call returns
    try await Task.sleep(for: .milliseconds(200))   // let it unwind and free its slot

    let value = try await withBoundedBlockingTimeout(
        .seconds(5), key: "nas", budget: budget
    ) { 7 }
    #expect(value == 7)
}
