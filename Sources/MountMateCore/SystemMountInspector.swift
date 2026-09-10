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
        // `statfs` on a genuinely wedged hard mount blocks inside the kernel and
        // cannot be interrupted by cooperative cancellation: `withTimeout` (a Task
        // racing `Task.sleep`) can only abandon its *own* task, it cannot un-park a
        // thread stuck in a syscall. If we ran the probe on Swift's cooperative
        // global executor pool, every wedged probe would permanently strand one of
        // that pool's small number of threads — and this engine health-checks on a
        // timer, so repeated probes against a dead hard mount would progressively
        // exhaust the pool and stall the whole app's concurrency runtime. That is
        // exactly the hang this file exists to prevent.
        //
        // So the probe runs on a dedicated, disposable OS thread instead: a wedged
        // probe then costs one ordinary pthread, parked forever but harmless, rather
        // than a slot in the structured-concurrency runtime. Do not "simplify" this
        // back into `withTimeout`/`Task`.
        await withCheckedContinuation { continuation in
            let state = ResumeOnce(continuation)
            let probe = Thread {
                var info = statfs()
                let ok = path.withCString { statfs($0, &info) } == 0
                state.finish(ok)
            }
            probe.stackSize = 512 * 1024
            probe.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                state.finish(false)
            }
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

/// Resumes a `CheckedContinuation` exactly once, whichever of two racing
/// completions — the probe thread finishing, or the timeout firing — happens
/// first. Resuming a `CheckedContinuation` a second time is a hard crash, so
/// double-resume must be structurally impossible, not merely unlikely.
private final class ResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var resumed = false

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
