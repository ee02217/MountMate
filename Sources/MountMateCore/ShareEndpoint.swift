import Foundation

/// Where a share should be mounted.
///
/// `.volumes` deliberately does NOT pin the mountpoint. NetFS always creates its own
/// directory under /Volumes; pre-creating one makes it mount at `<name>-1` instead,
/// which is invisible to anything configured to look at `<name>`. Let NetFS own it.
public enum MountPolicy: Sendable, Codable, Equatable {
    case volumes
    case custom(path: String)
}

/// Why a URL was refused as a share endpoint.
public enum ShareEndpointError: Error, Equatable, CustomStringConvertible {
    /// Only the schemes whose `f_mntfromname` form this package can derive are allowed.
    case unsupportedScheme(String?)
    /// `smb:///Share` and friends: no host to mount from.
    case missingHost
    /// `smb://host` with no share component.
    case missingShare

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            return """
                unsupported scheme \(scheme.map { "\"\($0)\"" } ?? "(none)"); \
                only smb:// and afp:// are supported
                """
        case .missingHost:
            return "the URL has no host"
        case .missingShare:
            return "the URL has no share path"
        }
    }
}

public struct ShareEndpoint: Sendable, Codable, Equatable, Identifiable {
    /// Schemes whose mounted `f_mntfromname` is the `//user@host/share` form that
    /// `mountFromIdentifier` produces. See the note on `mountFromIdentifier`.
    public static let supportedSchemes: Set<String> = ["smb", "afp"]

    public let id: UUID
    public var displayName: String
    /// Validated and stripped of any userinfo at construction. `private(set)` so the
    /// invariant cannot be reintroduced by assignment — build a new endpoint to change
    /// the URL and the checks run again.
    public private(set) var url: URL
    public var username: String
    public var mountPolicy: MountPolicy
    public var enabled: Bool
    public var readOnly: Bool

    /// Throws `ShareEndpointError` if `url` cannot be mounted by this engine.
    ///
    /// Two invariants are enforced here rather than trusted:
    ///
    /// 1. **No credential in the URL.** Spec §5.5 and §5.6 both require that no
    ///    password is ever persisted or placed in a URL — the password is a `passwd`
    ///    parameter to `NetFSMountURLSync` precisely so it never reaches a process
    ///    listing. But `ShareEndpoint` is `Codable` and milestone 3 writes it to
    ///    `endpoints.json`, and pasting `smb://user:pass@host/share` into a URL field
    ///    is completely ordinary. Userinfo is therefore stripped, not merely
    ///    discouraged: the stored URL cannot carry a secret because it cannot carry
    ///    userinfo at all. `username` is the authoritative account field.
    /// 2. **Only schemes whose mount identifier we can derive.** See
    ///    `mountFromIdentifier`.
    public init(
        id: UUID = UUID(),
        displayName: String,
        url: URL,
        username: String,
        mountPolicy: MountPolicy,
        enabled: Bool = true,
        readOnly: Bool = false
    ) throws {
        self.id = id
        self.displayName = displayName
        self.url = try Self.sanitized(url)
        self.username = username
        self.mountPolicy = mountPolicy
        self.enabled = enabled
        self.readOnly = readOnly
    }

    /// Rejects unmountable URLs and removes any userinfo.
    static func sanitized(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ShareEndpointError.unsupportedScheme(url.scheme)
        }
        let scheme = components.scheme?.lowercased()
        guard let scheme, supportedSchemes.contains(scheme) else {
            throw ShareEndpointError.unsupportedScheme(components.scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ShareEndpointError.missingHost
        }
        guard !components.path.trimmingCharacters(in: Self.slashes).isEmpty else {
            throw ShareEndpointError.missingShare
        }

        components.scheme = scheme
        // The whole point of this initializer.
        components.user = nil
        components.password = nil

        guard let sanitized = components.url else {
            throw ShareEndpointError.unsupportedScheme(scheme)
        }
        return sanitized
    }

    private static let slashes = CharacterSet(charactersIn: "/")

    /// The `f_mntfromname` value the kernel reports for this share once mounted,
    /// e.g. `//smbshare@192.168.1.67/Multimedia`. Used to find an existing mount
    /// regardless of which directory NetFS chose for it.
    ///
    /// SPEC DEBT (§5.5): the spec claims `nfs://` and WebDAV `https://` work because
    /// "NetFS dispatches on scheme". NetFS does — but this identifier does not: NFS
    /// reports `host:/export` and WebDAV an `http(s)` form, neither of which is
    /// `//user@host/share`. For such an endpoint `existingMount(for:)` would never
    /// match, so the engine would believe the share unmounted on every trigger and
    /// remount it — under `.volumes` that produces `<name>-1`, `<name>-2`, … on a
    /// 5-minute timer, which is the exact failure mode this project exists to close.
    /// The initializer therefore refuses every scheme but `smb` and `afp`. Before a
    /// protocol picker ships, either add per-scheme identifier derivation or narrow
    /// the spec — do not simply widen `supportedSchemes`.
    public var mountFromIdentifier: String {
        let host = url.host ?? ""
        let share = url.path.trimmingCharacters(in: Self.slashes)
        return "//\(username)@\(host)/\(share)"
    }
}

extension ShareEndpoint {
    /// Decoding re-runs validation: `endpoints.json` is a plain file a user can edit,
    /// so a URL arriving from disk gets no more trust than one typed into the UI.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            url: container.decode(URL.self, forKey: .url),
            username: container.decode(String.self, forKey: .username),
            mountPolicy: container.decode(MountPolicy.self, forKey: .mountPolicy),
            enabled: container.decode(Bool.self, forKey: .enabled),
            readOnly: container.decode(Bool.self, forKey: .readOnly)
        )
    }
}
