import Darwin
import Foundation
import NetFS

/// Mounts through NetFS with the authentication dialog disabled.
///
/// `kNAUIOptionNoUI` is the whole reason this app exists: AppleScript's `mount volume`
/// routes failures to NetAuthAgent, which puts a modal dialog on screen and blocks
/// until a human clicks it. There is no way to suppress that from a shell script.
public struct NetFSMountService: MountService {
    public init() {}

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

    public func mount(endpoint: ShareEndpoint, password: String) async throws -> String {
        let mountDirectory: URL
        switch endpoint.mountPolicy {
        case .volumes:
            mountDirectory = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case .custom(let path):
            mountDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            endpoint.url as CFURL,
            mountDirectory as CFURL,
            endpoint.username as CFString,
            password as CFString,
            Self.makeOpenOptions(),
            Self.makeMountOptions(policy: endpoint.mountPolicy, readOnly: endpoint.readOnly),
            &mountpoints
        )

        let paths = mountpoints?.takeRetainedValue() as? [String]

        guard status == 0 else {
            throw MountFailure(reason: Self.reason(for: status), status: status)
        }
        guard let path = paths?.first else {
            throw MountFailure(reason: .unknown, status: status)
        }
        return path
    }

    public func unmount(path: String, force: Bool) async throws {
        // NetFS exposes no unmount; use the BSD call.
        let flags = force ? MNT_FORCE : 0
        let result = path.withCString { Darwin.unmount($0, flags) }
        guard result == 0 else {
            throw MountFailure(reason: .mountpointBusy, status: errno)
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
