import Foundation

/// A stream of reasons to check the endpoints.
///
/// Implementations are thin adapters over a system API. All of the interesting
/// behaviour lives in `MountCoordinator`, so the untestable parts stay tiny.
public protocol TriggerSource: Sendable {
    /// Events from the moment the stream is created. Sources are single-consumer:
    /// each `events` access starts its own stream and its own underlying observer,
    /// so access it once and iterate that value.
    var events: AsyncStream<TriggerEvent> { get }
}
