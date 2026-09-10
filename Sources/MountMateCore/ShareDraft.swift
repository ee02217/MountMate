import Foundation

/// An endpoint as it exists while someone is typing it.
///
/// `ShareEndpoint` validates in its initializer and throws, which is exactly right
/// for a file on disk and useless for a form: a host is invalid for as long as it is
/// half-typed. This holds the loose parts; `validated()` is the single gate, and it
/// goes through `ShareEndpoint.init` so the form and the file loader cannot disagree
/// about what is acceptable.
public struct ShareDraft: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var scheme: String
    public var host: String
    public var sharePath: String
    public var username: String
    public var mountPolicy: MountPolicy
    public var enabled: Bool
    public var readOnly: Bool

    /// What the user typed into the password field, if anything. Never persisted to
    /// `endpoints.json`; written to the Keychain on save.
    public var password: String?
    /// Whether a password already exists in the Keychain for this share. The value is
    /// never read into the form — only whether there is one.
    public var hasStoredPassword: Bool

    public init(id: UUID = UUID()) {
        self.id = id
        self.displayName = ""
        self.scheme = "smb"
        self.host = ""
        self.sharePath = ""
        self.username = ""
        self.mountPolicy = .volumes
        self.enabled = true
        self.readOnly = false
        self.password = nil
        self.hasStoredPassword = false
    }

    public init(_ endpoint: ShareEndpoint, hasStoredPassword: Bool) {
        self.id = endpoint.id
        self.displayName = endpoint.displayName
        self.scheme = endpoint.url.scheme ?? "smb"
        self.host = endpoint.url.host ?? ""
        self.sharePath = Self.trimmed(endpoint.url.path)
        self.username = endpoint.username
        self.mountPolicy = endpoint.mountPolicy
        self.enabled = endpoint.enabled
        self.readOnly = endpoint.readOnly
        self.password = nil
        self.hasStoredPassword = hasStoredPassword
    }

    /// The parts that make up the Keychain key and the mount identifier.
    ///
    /// Deliberately not the whole value: `displayName`, `enabled` and `readOnly`
    /// change constantly, and treating those as identity would move a credential
    /// every time someone renamed a share.
    public func identityDiffers(from other: ShareDraft) -> Bool {
        host != other.host
            || sharePath != other.sharePath
            || username != other.username
            || scheme != other.scheme
    }

    /// Throws the same `ShareEndpointError` the file loader reports.
    public func validated() throws -> ShareEndpoint {
        let path = Self.trimmed(sharePath)
        var components = URLComponents()
        components.scheme = scheme.lowercased()
        components.host = host
        components.path = path.isEmpty ? "" : "/\(path)"

        guard let url = components.url else {
            throw ShareEndpointError.missingHost
        }

        return try ShareEndpoint(
            id: id,
            displayName: displayName.isEmpty ? path : displayName,
            url: url,
            username: username,
            mountPolicy: mountPolicy,
            enabled: enabled,
            readOnly: readOnly
        )
    }

    private static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
