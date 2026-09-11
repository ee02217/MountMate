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

    /// Throws a `ShareDraftProblem`, worded for the Settings form.
    public func validated() throws -> ShareEndpoint {
        // A space pasted along with an address is not worth refusing a save over.
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ShareDraftProblem.missingHost }

        let path = Self.trimmed(sharePath)
        guard !path.isEmpty else { throw ShareDraftProblem.missingShare }

        var components = URLComponents()
        components.scheme = scheme.lowercased()
        components.host = host
        components.path = "/\(path)"
        // Nil for a host no address can hold — a space or a slash inside it. This used
        // to be reported as "no host" while the field visibly had one.
        guard let url = components.url else { throw ShareDraftProblem.invalidHost(host) }

        do {
            return try ShareEndpoint(
                id: id,
                displayName: displayName.isEmpty ? path : displayName,
                url: url,
                username: username,
                mountPolicy: mountPolicy,
                enabled: enabled,
                readOnly: readOnly
            )
        } catch let error as ShareEndpointError {
            switch error {
            case .unsupportedScheme(let scheme): throw ShareDraftProblem.unsupportedScheme(scheme ?? "")
            case .missingHost: throw ShareDraftProblem.invalidHost(host)
            case .missingShare: throw ShareDraftProblem.missingShare
            }
        }
    }

    private static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Why Save refused a share, in the Settings form's own words.
///
/// Deliberately separate from `ShareEndpointError`. That one is what the file loader
/// reports for a broken entry in endpoints.json, where "row" and "URL" are accurate:
/// the file is a list of entries with a `url` field. The form has neither — it has
/// Host and Share fields — so its messages name those.
public enum ShareDraftProblem: Error, Equatable {
    case missingHost
    /// Something is in the Host field, but no address can hold it.
    case invalidHost(String)
    case missingShare
    /// Not reachable from the form today, which only makes SMB shares; kept so a
    /// draft that somehow carries another scheme is refused in plain words too.
    case unsupportedScheme(String)

    public var message: String {
        switch self {
        case .missingHost:
            return "Enter the server's host name or IP address."
        case .invalidHost(let host):
            return "The host \u{201C}\(host)\u{201D} isn't a valid name or IP address."
        case .missingShare:
            return "Enter the share's name."
        case .unsupportedScheme:
            return "Only SMB and AFP shares are supported."
        }
    }
}
