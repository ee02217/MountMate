import Foundation

/// Caps how many blocking calls may be outstanding against one server at a time.
///
/// Why this exists: `runBlocking` bounds the *caller's* wall clock, never the C call
/// itself. When the deadline wins, the worker thread stays parked in the kernel for as
/// long as the call takes — forever, against a server whose SMB service is wedged. One
/// stranded thread is harmless; one per attempt is not. With the retry ladder driving
/// a fresh attempt every time, a permanently wedged server strands a thread per
/// attempt until the process hits its thread limit and dies — the unattended failure
/// this package exists to prevent.
///
/// `MountEngine`'s `inFlight` guard cannot catch this. It tracks the *awaited* call and
/// releases in `defer`, which runs the moment the deadline fires — precisely the moment
/// the thread becomes stranded. The guard's lifetime ends where the leak begins, and
/// retries are sequential anyway, so it is never even consulted.
///
/// This is the mount-side counterpart of `WedgedPathRegistry`, which solved the same
/// problem for liveness probes. The difference is the re-arm signal. A probe re-arms
/// when the mount table entry changes identity; a mount attempt has no such signal, so
/// the slot is held until **the abandoned call actually returns**. That is the correct
/// signal: these calls are parked inside NetAuthSysAgent, so whatever unwedges the
/// server (the agent restarting, the connection breaking) is the same event that
/// returns them and reopens the slot.
///
/// If every slot stays taken forever, further attempts are refused forever — and that
/// is right, not a lockout to design around. A new call in that state cannot succeed:
/// it would park in the same wedged agent. Refusing costs nothing and reports the truth;
/// attempting costs a thread and reports the same failure 45 seconds later.
///
/// Lock-based rather than an actor because `release` runs on the abandoned worker
/// thread, inside a synchronous C-shaped body with no suspension point at which an
/// actor could be awaited.
public final class BlockingCallBudget: @unchecked Sendable {
    /// Process-wide by default: the budget being protected is the process's thread
    /// count, and a per-instance budget would be defeated by the second
    /// `NetFSMountService` anyone constructs. Same reasoning as
    /// `WedgedPathRegistry.shared`.
    public static let shared = BlockingCallBudget()

    /// Three, not one. One stuck call is the common transient case and should not
    /// disable the endpoint; three concurrent strands against one server is already
    /// firm evidence that it is wedged rather than slow. Small enough that the
    /// user's handful of endpoints stays a rounding error against the thread limit.
    private let limit: Int
    private let lock = NSLock()
    private var outstandingByKey: [String: Int] = [:]

    public init(limit: Int = 3) {
        self.limit = limit
    }

    /// Takes a slot for `key`, or reports that the key is at its limit.
    func claim(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = outstandingByKey[key, default: 0]
        guard current < limit else { return false }
        outstandingByKey[key] = current + 1
        return true
    }

    /// Returns a slot. Clamped at zero: this runs on a worker thread that may outlive
    /// everything that could reason about the pairing, so it must never corrupt the
    /// count if it is somehow reached twice.
    func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        let current = outstandingByKey[key, default: 0]
        guard current > 1 else {
            outstandingByKey.removeValue(forKey: key)
            return
        }
        outstandingByKey[key] = current - 1
    }

    /// Test/diagnostic accessor.
    func outstanding(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return outstandingByKey[key, default: 0]
    }
}
