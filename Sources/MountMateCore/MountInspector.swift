import Foundation

public struct MountedVolume: Sendable, Equatable {
    /// `f_mntfromname`, e.g. `//nasuser@192.0.2.10/Multimedia`.
    public let from: String
    /// `f_mntonname`, e.g. `/Volumes/Multimedia`.
    public let on: String

    public init(from: String, on: String) {
        self.from = from
        self.on = on
    }
}

/// What is at a path, for the purpose of deciding whether a mount can land there.
///
/// `absent` means "nothing NetFS would trip over" and covers both an empty slot and
/// a non-directory: NetFS creates the directory in the first case and fails in the
/// second, and the second has no remedy this app could offer that it does not offer
/// for any other mount failure.
public enum DirectoryState: Sendable, Equatable {
    case absent
    case empty
    case nonEmpty
}

public protocol MountInspector: Sendable {
    func mountedVolumes() async -> [MountedVolume]
    /// Whether the mount at `path` actually answers. A mount can be listed but dead.
    func isResponsive(path: String) async -> Bool
    /// What occupies `path`. Consulted only when the mount table says nothing is
    /// mounted there, so it never touches a wedged mount.
    func directoryState(at path: String) async -> DirectoryState
}
