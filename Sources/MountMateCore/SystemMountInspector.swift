import Foundation

/// Reads the kernel mount table directly.
///
/// Uses `MNT_NOWAIT` rather than shelling out to `mount`, and rather than `MNT_WAIT`:
/// NOWAIT returns cached values and will not block on an unreachable server. Blocking
/// here is what made the previous shell implementation hang.
public struct SystemMountInspector: MountInspector {
    /// How long a responsiveness probe may block before the mount is declared dead.
    private let probeTimeout: Duration
    private let wedgedPaths: WedgedPathRegistry
    /// The blocking liveness syscall. A seam so tests can supply a probe that hangs on
    /// demand — a genuinely wedged mount cannot be manufactured in a unit test.
    private let probe: @Sendable (String) -> Bool

    public init(probeTimeout: Duration = .seconds(10)) {
        self.init(
            probeTimeout: probeTimeout,
            wedgedPaths: .shared,
            probe: Self.statfsProbe
        )
    }

    init(
        probeTimeout: Duration,
        wedgedPaths: WedgedPathRegistry,
        probe: @escaping @Sendable (String) -> Bool
    ) {
        self.probeTimeout = probeTimeout
        self.wedgedPaths = wedgedPaths
        self.probe = probe
    }

    public func mountedVolumes() async -> [MountedVolume] {
        // `getmntinfo` is documented as owning its results buffer and is explicitly
        // not thread-safe: a second caller can overwrite or free the buffer the first
        // is still reading. `MountInspector` is `Sendable` and this is a public struct,
        // so nothing stops two concurrent callers — today only `MountEngine`'s actor
        // serialises them, which is a promise the type must keep on its own.
        // `getmntinfo_r_np` (macOS 10.13+, well under this package's .v14 floor)
        // hands ownership of the buffer to the caller instead, which makes concurrent
        // calls safe. MNT_NOWAIT must stay: MNT_WAIT can block on a dead server.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard let buffer else { return [] }
        defer { free(buffer) }
        guard count > 0 else { return [] }

        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return MountedVolume(
                from: Self.string(from: &entry.f_mntfromname),
                on: Self.string(from: &entry.f_mntonname)
            )
        }
    }

    public func isResponsive(path: String) async -> Bool {
        // A path already known to hang is reported dead without touching it. This is
        // what keeps the stranded probe thread a one-off rather than one per health
        // check; see `WedgedPathRegistry`.
        let currentFrom = await mountFromName(for: path)
        if await wedgedPaths.shouldShortCircuit(path: path, currentFrom: currentFrom) {
            return false
        }

        // `statfs` on a genuinely wedged hard mount blocks inside the kernel and
        // cannot be interrupted by cooperative cancellation. `runBlocking` gives it a
        // dedicated, disposable OS thread so a wedged probe costs one ordinary pthread
        // rather than a slot in the structured-concurrency runtime. Do not "simplify"
        // this back into a plain `Task`.
        let probe = self.probe
        guard let answer = await runBlocking(timeout: probeTimeout, { probe(path) }) else {
            // The deadline won: the worker thread is now parked forever. Remember the
            // path so the next probe costs nothing.
            await wedgedPaths.recordWedged(path: path, from: currentFrom)
            return false
        }
        await wedgedPaths.clear(path: path)
        return answer
    }

    private func mountFromName(for path: String) async -> String? {
        await mountedVolumes().first { $0.on == path }?.from
    }

    private static let statfsProbe: @Sendable (String) -> Bool = { path in
        var info = statfs()
        return path.withCString { statfs($0, &info) } == 0
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
