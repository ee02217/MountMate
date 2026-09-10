import Foundation

/// Where a share is supposed to land.
///
/// Deriving this is **not** the same as pinning it. `MountPolicy.volumes`
/// deliberately lets NetFS create the directory, because pre-creating one is exactly
/// what makes NetFS choose `<name>-1` instead. This computes the expected path only
/// so a mount can be *checked* against it afterwards (spec §9.1).
public enum ExpectedMountpoint {
    public static func path(for endpoint: ShareEndpoint) -> String {
        switch endpoint.mountPolicy {
        case .custom(let path):
            return normalised(path)
        case .volumes:
            let share = endpoint.url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "/Volumes/\(share)"
        }
    }

    /// Whether `actual` is the place this endpoint was supposed to mount.
    ///
    /// Compared after normalising a trailing slash: `/Volumes/Multimedia/` is the
    /// same place as `/Volumes/Multimedia`, and treating it as a mismatch would
    /// unmount a perfectly good mount.
    public static func matches(_ actual: String, for endpoint: ShareEndpoint) -> Bool {
        normalised(actual) == normalised(path(for: endpoint))
    }

    private static func normalised(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
