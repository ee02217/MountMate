import Testing
import Foundation
@testable import MountMateCore

// MARK: - Cooperative operations

@Test func returnsValueWhenOperationFinishesInTime() async throws {
    let value = try await withTimeout(.milliseconds(500)) { 42 }
    #expect(value == 42)
}

@Test func throwsTimedOutWhenOperationOverruns() async {
    do {
        _ = try await withTimeout(.milliseconds(50)) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
        Issue.record("expected a timeout")
    } catch let failure as MountFailure {
        #expect(failure.reason == .timedOut)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func propagatesOperationError() async {
    struct Boom: Error {}
    do {
        _ = try await withTimeout(.seconds(5)) { throw Boom() }
        Issue.record("expected the operation error")
    } catch is Boom {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Non-cancellable operations
//
// These are the tests that matter. The cooperative tests above pass just as happily
// against an implementation that cannot bound wall-clock time at all, because
// `Task.sleep` *is* cancellable: a task group that cancels its children and then
// awaits them looks correct as long as the children cooperate. `NetFSMountURLSync`,
// `Darwin.unmount` and `statfs` do not cooperate — they park in the kernel with no
// suspension point at which cancellation could be observed. So each test below uses
// a body that genuinely cannot be cancelled, and asserts *measured elapsed time*
// rather than merely that `.timedOut` was thrown. Throwing on schedule while the
// caller stays parked for the full ten seconds is the bug these exist to catch.

/// Bodies here block for this long. Comfortably longer than any deadline under test,
/// short enough that the test process is not left holding parked threads.
private let blockingDuration: TimeInterval = 5

@Test func runBlockingReleasesTheCallerOnScheduleDespiteAnUncancellableBody() async {
    let clock = ContinuousClock()
    let start = clock.now
    let result: Bool? = await runBlocking(timeout: .milliseconds(200)) {
        Thread.sleep(forTimeInterval: blockingDuration)
        return true
    }
    let elapsed = clock.now - start

    #expect(result == nil)
    #expect(elapsed < .milliseconds(900), "released after \(elapsed), deadline was 200ms")
}

@Test func runBlockingReturnsTheValueOfABodyThatFinishesInTime() async {
    let result: Int? = await runBlocking(timeout: .seconds(5)) { 7 }
    #expect(result == 7)
}

@Test func withBlockingTimeoutReportsTheDeadlineAsATimeout() async {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        _ = try await withBlockingTimeout(.milliseconds(200)) {
            Thread.sleep(forTimeInterval: blockingDuration)
            return true
        }
        Issue.record("expected a timeout")
    } catch let failure as MountFailure {
        #expect(failure.reason == .timedOut)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(clock.now - start < .milliseconds(900))
}

@Test func withTimeoutReleasesTheCallerOnScheduleDespiteAnUncancellableBody() async {
    // A semaphore wait on a dedicated thread: uncancellable by construction. Before
    // the rewrite the caller was held for the body's full duration even though
    // `.timedOut` was thrown "on time".
    let gate = DispatchSemaphore(value: 0)
    let clock = ContinuousClock()
    let start = clock.now
    do {
        _ = try await withTimeout(.milliseconds(200)) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let thread = Thread {
                    _ = gate.wait(timeout: .now() + blockingDuration)
                    continuation.resume(returning: true)
                }
                thread.start()
            }
        }
        Issue.record("expected a timeout")
    } catch let failure as MountFailure {
        #expect(failure.reason == .timedOut)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    let elapsed = clock.now - start

    #expect(elapsed < .milliseconds(900), "released after \(elapsed), deadline was 200ms")
    gate.signal()
}

@Test func withTimeoutPropagatesCallerCancellation() async {
    // Cancelling the enclosing task must surface as `CancellationError`, not as a
    // mount failure: shutting down is not an outage.
    let task = Task { () -> (any Error)? in
        do {
            _ = try await withTimeout(.seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            return nil
        } catch {
            return error
        }
    }
    try? await Task.sleep(for: .milliseconds(80))
    task.cancel()

    let error = await task.value
    #expect(error is CancellationError)
}

@Test func clampedNanosecondsNeverGoesNegative() {
    #expect(Duration.seconds(-5).clampedNanoseconds == 0)
    #expect(Duration.milliseconds(250).clampedNanoseconds == 250_000_000)
    #expect(Duration.seconds(2).clampedNanoseconds == 2_000_000_000)
}
