import Foundation

/// The only route to the mount system. `MountEngine` depends on this, never on NetFS
/// directly, so the state machine is testable with no network and no NAS.
public protocol MountService: Sendable {
    /// Mounts the endpoint and returns the resulting mount path.
    func mount(endpoint: ShareEndpoint, password: String) async throws -> String
    /// Unmounts whatever is mounted at `path`.
    func unmount(path: String, force: Bool) async throws
}
