import Foundation
@testable import MountMateCore

/// A source the test drives by hand.
///
/// The stream is created once in `init` and handed out unchanged, so `yield` before
/// iteration still lands: `AsyncStream` buffers until consumed.
final class FakeTriggerSource: TriggerSource, @unchecked Sendable {
    let events: AsyncStream<TriggerEvent>
    private let continuation: AsyncStream<TriggerEvent>.Continuation

    init() {
        var captured: AsyncStream<TriggerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func yield(_ event: TriggerEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
}
