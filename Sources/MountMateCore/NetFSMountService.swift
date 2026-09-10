import Darwin
import Foundation
import NetFS

/// Mounts through NetFS with the authentication dialog disabled.
///
/// `kNAUIOptionNoUI` is the whole reason this app exists: AppleScript's `mount volume`
/// routes failures to NetAuthAgent, which puts a modal dialog on screen and blocks
/// until a human clicks it. There is no way to suppress that from a shell script.
///
/// Both calls this type makes — `NetFSMountURLSync` and `Darwin.unmount` — are
/// synchronous C calls with no suspension point, so `async` alone would not make them
/// abandonable and cooperative cancellation could never reach them. They run through
/// `runBlocking`, which gives each a dedicated thread and a real wall-clock deadline.
/// Without that, an `await service.mount(...)` that never returns pins the caller
/// forever no matter what deadline the caller thinks it applied.
public struct NetFSMountService: MountService {
    /// The blocking NetFS call. A seam so tests can supply one that hangs on demand —
    /// a wedged SMB service cannot be manufactured in a unit test. Same pattern as
    /// `SystemMountInspector.probe`.
    typealias BlockingMountCall = @Sendable (ShareEndpoint, String, URL) -> MountOutcome
    /// The blocking BSD unmount, seamed for the same reason.
    typealias BlockingUnmountCall = @Sendable (String, Int32) -> UnmountOutcome

    private let mountDeadline: Duration
    private let unmountDeadline: Duration
    private let budget: BlockingCallBudget
    private let mountCall: BlockingMountCall
    private let unmountCall: BlockingUnmountCall

    public init(
        mountDeadline: Duration = .seconds(45),
        unmountDeadline: Duration = .seconds(20)
    ) {
        self.init(
            mountDeadline: mountDeadline,
            unmountDeadline: unmountDeadline,
            budget: .shared,
            mountCall: Self.netFSMountCall,
            unmountCall: Self.bsdUnmountCall
        )
    }

    init(
        mountDeadline: Duration,
        unmountDeadline: Duration,
        budget: BlockingCallBudget,
        mountCall: @escaping BlockingMountCall,
        unmountCall: @escaping BlockingUnmountCall
    ) {
        self.mountDeadline = mountDeadline
        self.unmountDeadline = unmountDeadline
        self.budget = budget
        self.mountCall = mountCall
        self.unmountCall = unmountCall
    }

    public static func makeOpenOptions() -> NSMutableDictionary {
        let options = NSMutableDictionary()
        options[kNAUIOptionKey] = kNAUIOptionNoUI
        return options
    }

    public static func makeMountOptions(
        policy: MountPolicy, readOnly: Bool
    ) -> NSMutableDictionary {
        let options = NSMutableDictionary()
        options[kNetFSSoftMountKey] = true
        if case .custom = policy {
            options[kNetFSMountAtMountDirKey] = true
        }
        if readOnly {
            options[kNetFSMountFlagsKey] = MNT_RDONLY
        }
        return options
    }

    /// What the blocking NetFS call reported, carried back across the thread hand-off.
    struct MountOutcome: Sendable {
        let status: Int32
        let firstPath: String?
    }

    public func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        let mountDirectory: URL
        switch endpoint.mountPolicy {
        case .volumes:
            mountDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case .custom(let path):
            mountDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        // Bounded and self-disposing, not merely deadlined.
        //
        // `withBlockingTimeout` releases the caller on schedule but cannot cancel the
        // NetFS call, and the parked call is not idle: it is a live mount request that
        // is still being worked. On 2026-09-10 seven of them completed the instant
        // NetAuthSysAgent was restarted, each landing on the next free path, leaving
        // Multimedia-1 … Multimedia-6 behind. `MountEngine`'s mountpoint guard never
        // saw any of them, because it inspects only the path handed back to the caller
        // and an abandoned attempt returns to nobody.
        //
        // So two things. The budget refuses to start a second request while one is
        // still outstanding for this share — that race is what produced two mounts at
        // two paths. And `onAbandoned` gives the worker thread the outcome the caller
        // never received, so the attempt verifies and cleans up after itself.
        let mountCall = self.mountCall
        let unmountCall = self.unmountCall
        let outcome = try await withBoundedBlockingTimeout(
            mountDeadline,
            key: Self.budgetKey(for: endpoint),
            budget: budget,
            onAbandoned: { outcome in
                Self.disposeOfAbandonedMount(
                    outcome, endpoint: endpoint, unmountCall: unmountCall
                )
            }
        ) {
            mountCall(endpoint, password, mountDirectory)
        }

        guard outcome.status == 0 else {
            throw MountFailure(reason: Self.reason(for: outcome.status), status: outcome.status)
        }
        guard let path = outcome.firstPath else {
            throw MountFailure(reason: .unknown, status: outcome.status)
        }
        return path
    }

    /// `errno` is only meaningful on the thread that made the failing call, so it is
    /// captured there rather than read back afterwards.
    struct UnmountOutcome: Sendable {
        let succeeded: Bool
        let errorNumber: Int32
    }

    public func unmount(path: String, force: Bool) async throws {
        let flags = force ? MNT_FORCE : 0
        let unmountCall = self.unmountCall
        let outcome = try await withBlockingTimeout(unmountDeadline) {
            unmountCall(path, flags)
        }
        guard outcome.succeeded else {
            // Report the real errno rather than assuming EBUSY: "the server is gone"
            // and "something still has the mountpoint open" want different responses
            // from the trigger layer, and flattening both to `.mountpointBusy` threw
            // that away.
            throw MountFailure(
                reason: Self.reason(for: outcome.errorNumber), status: outcome.errorNumber
            )
        }
    }

    /// The share, not the server. The hazard being prevented is two live mount
    /// requests for the *same* share racing for one mountpoint, which is what put
    /// seven mounts on seven paths. Two different shares land at different paths and
    /// cannot collide, so one wedged share must not refuse another on the same host.
    static func budgetKey(for endpoint: ShareEndpoint) -> String {
        endpoint.mountFromIdentifier
    }

    /// Disposes of the result of an attempt nobody is waiting for any more.
    ///
    /// Runs on the abandoned worker thread once the NetFS call finally returns. The
    /// policy deliberately matches `MountEngine`'s for a delivered result — accept the
    /// expected path, tear down anything else — because the two are the same decision
    /// about the same mount, differing only in who is left to make it. Exactly one of
    /// them ever runs for a given attempt: `ResumeOnce` has one winner.
    ///
    /// A mount that reached the *expected* path is left alone. It is the mount we
    /// wanted; the next sweep finds it in the mount table and adopts it. Tearing it
    /// down would discard a good mount and guarantee another attempt.
    static func disposeOfAbandonedMount(
        _ outcome: MountOutcome,
        endpoint: ShareEndpoint,
        unmountCall: BlockingUnmountCall
    ) {
        // A late failure has nothing to dispose of. Acting on a path NetFS never
        // returned would be unmounting something this attempt did not create.
        guard outcome.status == 0, let path = outcome.firstPath else { return }
        guard !ExpectedMountpoint.matches(path, for: endpoint) else { return }
        // Not forced: a mount this attempt created moments ago has nothing open on
        // it, and forcing would be reaching past a refusal we have no reason to expect.
        _ = unmountCall(path, 0)
    }

    private static let bsdUnmountCall: BlockingUnmountCall = { path, flags in
        // NetFS exposes no unmount; use the BSD call. `errno` is only meaningful on
        // the thread that made the failing call, so it is read here rather than after.
        let result = path.withCString { Darwin.unmount($0, flags) }
        return UnmountOutcome(succeeded: result == 0, errorNumber: errno)
    }

    private static let netFSMountCall: BlockingMountCall = { endpoint, password, directory in
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            endpoint.url as CFURL,
            directory as CFURL,
            endpoint.username as CFString,
            // The password stays a `passwd` CFString parameter and never enters the
            // URL, so it cannot appear in a process listing.
            password as CFString,
            makeOpenOptions(),
            makeMountOptions(policy: endpoint.mountPolicy, readOnly: endpoint.readOnly),
            &mountpoints
        )
        let paths = mountpoints?.takeRetainedValue() as? [String]
        return MountOutcome(status: status, firstPath: paths?.first)
    }

    /// Maps NetFS/POSIX status codes onto actionable causes.
    static func reason(for status: Int32) -> MountFailureReason {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM): return .authenticationFailed
        case Int32(ETIMEDOUT), Int32(EHOSTDOWN), Int32(EHOSTUNREACH),
             Int32(ENETDOWN), Int32(ENETUNREACH): return .hostUnreachable
        case Int32(ENOENT), Int32(ENODEV): return .shareNotFound
        case Int32(EBUSY): return .mountpointBusy
        default: return .unknown
        }
    }
}
