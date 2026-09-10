import Foundation

/// An exclusive, process-wide lock: only one MountMate may run at a time.
///
/// `MountEngine.inFlight` prevents two attempts inside one process and nothing
/// prevented two processes. On 2026-09-10 a development build and the installed build
/// ran together, both saw no existing mount, and both mounted — the loser landing at
/// `<name>-1` and leaving a placeholder that broke everything else (spec §9.1).
///
/// `flock` rather than a pid file: the kernel releases it when the process exits,
/// however it exits, so a crash cannot leave a stale lock that blocks every future
/// launch.
public final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    /// `nil` when another process already holds the lock.
    public init?(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        descriptor = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }

        // LOCK_NB: fail immediately rather than waiting for the other copy to quit.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func defaultPath() -> URL {
        JSONEndpointStore.defaultDirectory().appendingPathComponent("instance.lock")
    }
}
