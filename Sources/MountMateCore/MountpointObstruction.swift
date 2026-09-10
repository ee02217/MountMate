import Foundation

/// What occupies the path a share is supposed to mount at.
///
/// `ExpectedMountpoint` records that pre-creating the directory is *what causes* NetFS
/// to choose `<name>-1`. Read in reverse, "something already occupies the expected
/// path" is an exact predicate for "this attempt will land in the wrong place" — so a
/// blocked mountpoint can be diagnosed *before* mounting rather than discovered by
/// mounting into it and undoing the result.
///
/// The cases exist to carry distinct remedies, not to describe the filesystem. Two
/// situations that a person would fix the same way share a case.
public enum MountpointObstruction: Sendable, Equatable {
    /// Nothing is in the way; NetFS will create the directory and mount there.
    case clear
    /// A leftover directory. `sudo rmdir` clears it — the app cannot, because
    /// `/Volumes` is `root:wheel`.
    case emptyDirectory
    /// A directory with contents. `rmdir` would fail, so it must not be suggested.
    case nonEmptyDirectory
    /// A different volume is mounted there and must be ejected.
    case otherVolume(from: String)

    /// The mount-table half, consulted first because it costs no syscall and cannot
    /// block. Returns `nil` when the table cannot decide and the filesystem must be
    /// asked — which is the only path that touches the disk.
    ///
    /// Precondition: the caller has already established that the endpoint has no
    /// mount of its own at `expectedPath` (see `EndpointMounts.partition`), so any
    /// volume found here belongs to something else.
    public static func fromMountTable(
        expectedPath: String, volumes: [MountedVolume]
    ) -> MountpointObstruction? {
        guard let occupant = volumes.first(where: { $0.on == expectedPath }) else {
            return nil
        }
        return .otherVolume(from: occupant.from)
    }

    /// The filesystem half, reached only when the mount table had no answer.
    public static func fromDirectory(_ state: DirectoryState) -> MountpointObstruction {
        switch state {
        case .absent: return .clear
        case .empty: return .emptyDirectory
        case .nonEmpty: return .nonEmptyDirectory
        }
    }
}
