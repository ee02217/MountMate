import Testing
import Foundation
@testable import MountMateCore

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
