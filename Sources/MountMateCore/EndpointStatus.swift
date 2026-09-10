import Foundation

/// One endpoint, as the UI needs to see it.
///
/// A flattened value rather than a reference to the engine: the menu renders on the
/// main actor and must never await an actor to draw a row.
public struct EndpointStatus: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let state: MountState
    public let enabled: Bool

    public init(id: UUID, displayName: String, state: MountState, enabled: Bool) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.enabled = enabled
    }

    /// Where it is attached right now, if it is attached at all.
    ///
    /// `.stale` counts: the volume is still mounted, just unresponsive, so revealing
    /// it in Finder is still meaningful.
    public var mountPath: String? {
        switch state {
        case .mounted(let path), .stale(let path):
            return path
        case .idle, .mounting, .failed:
            return nil
        }
    }
}
