import Foundation

/// Remembers mountpoints whose responsiveness probe hit its deadline, so the next
/// health check short-circuits instead of stranding another thread.
///
/// Why this exists: a probe that times out leaves its worker thread parked in the
/// kernel forever (see `runBlocking`). One stranded thread is genuinely harmless. One
/// stranded thread *per probe* is not: the 5-minute backstop sweep re-probes every
/// endpoint, so a permanently wedged hard mount would strand ~12 threads an hour,
/// ~288 a day, on a machine expected to run unattended for months. That reaches the
/// per-process thread limit in days to weeks and the symptom is process death — the
/// same class of unattended failure this package exists to prevent.
///
/// A wedged path stays short-circuited until the mount table's entry for it *changes
/// identity or disappears*, which is exactly what happens when the mount is cleared or
/// re-established. Re-arming on that signal rather than on a timer means we never
/// re-probe a path that is still the same dead mount.
public actor WedgedPathRegistry {
    /// Process-wide by default: the thread budget being protected is the process's, and
    /// a per-instance registry would be defeated by the second `SystemMountInspector`
    /// anyone constructs.
    public static let shared = WedgedPathRegistry()

    /// path -> the `f_mntfromname` the mount table reported when the probe timed out
    /// (`nil` if the path was not in the table at all).
    private var wedged: [String: String?] = [:]

    public init() {}

    /// Whether `path` is a known-wedged mount that should be reported dead without
    /// probing. Passing the path's current `f_mntfromname` (or `nil` if it is no
    /// longer mounted) lets the registry re-arm itself when the mount changes.
    func shouldShortCircuit(path: String, currentFrom: String?) -> Bool {
        guard let recordedFrom = wedged[path] else { return false }
        if recordedFrom == currentFrom { return true }
        // Different mount, or no mount at all: whatever was wedged is gone.
        wedged.removeValue(forKey: path)
        return false
    }

    func recordWedged(path: String, from: String?) {
        wedged[path] = .some(from)
    }

    func clear(path: String) {
        wedged.removeValue(forKey: path)
    }

    /// Test/diagnostic accessor.
    func isRecorded(path: String) -> Bool {
        wedged[path] != nil
    }
}
