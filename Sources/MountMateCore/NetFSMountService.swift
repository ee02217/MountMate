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
    private let mountDeadline: Duration
    private let unmountDeadline: Duration

    public init(
        mountDeadline: Duration = .seconds(45),
        unmountDeadline: Duration = .seconds(20)
    ) {
        self.mountDeadline = mountDeadline
        self.unmountDeadline = unmountDeadline
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

        let outcome = try await withBlockingTimeout(mountDeadline) { () -> MountOutcome in
            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                endpoint.url as CFURL,
                mountDirectory as CFURL,
                endpoint.username as CFString,
                // The password stays a `passwd` CFString parameter and never enters
                // the URL, so it cannot appear in a process listing.
                password as CFString,
                Self.makeOpenOptions(),
                Self.makeMountOptions(
                    policy: endpoint.mountPolicy, readOnly: endpoint.readOnly
                ),
                &mountpoints
            )
            let paths = mountpoints?.takeRetainedValue() as? [String]
            return MountOutcome(status: status, firstPath: paths?.first)
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
        // NetFS exposes no unmount; use the BSD call.
        let flags = force ? MNT_FORCE : 0
        let outcome = try await withBlockingTimeout(unmountDeadline) { () -> UnmountOutcome in
            let result = path.withCString { Darwin.unmount($0, flags) }
            return UnmountOutcome(succeeded: result == 0, errorNumber: errno)
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
