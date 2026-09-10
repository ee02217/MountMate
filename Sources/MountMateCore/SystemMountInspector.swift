import Foundation

/// Reads the kernel mount table directly.
///
/// Uses `getmntinfo(MNT_NOWAIT)` rather than shelling out to `mount`, and rather than
/// `MNT_WAIT`: NOWAIT returns cached values and will not block on an unreachable
/// server. Blocking here is what made the previous shell implementation hang.
public struct SystemMountInspector: MountInspector {
    public init() {}

    public func mountedVolumes() async -> [MountedVolume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return MountedVolume(
                from: Self.string(from: &entry.f_mntfromname),
                on: Self.string(from: &entry.f_mntonname)
            )
        }
    }

    public func isResponsive(path: String) async -> Bool {
        // statfs on a soft-mounted dead share returns an error rather than hanging,
        // but wrap it anyway: a hard mount from elsewhere could still block.
        let probe: @Sendable () async -> Bool = {
            var info = statfs()
            return path.withCString { statfs($0, &info) } == 0
        }
        do {
            return try await withTimeout(.seconds(10)) { await probe() }
        } catch {
            return false
        }
    }

    /// `f_mntfromname` / `f_mntonname` are fixed-size C char tuples MAXPATHLEN wide.
    /// Take their address and rebind to read them as C strings. This exact form was
    /// verified against the live mount table before this plan was written.
    private static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }
}
