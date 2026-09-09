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

public struct ShareEndpoint: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var url: URL
    public var username: String
    public var mountPolicy: MountPolicy
    public var enabled: Bool
    public var readOnly: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        url: URL,
        username: String,
        mountPolicy: MountPolicy,
        enabled: Bool = true,
        readOnly: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.username = username
        self.mountPolicy = mountPolicy
        self.enabled = enabled
        self.readOnly = readOnly
    }

    /// The `f_mntfromname` value the kernel reports for this share once mounted,
    /// e.g. `//smbshare@192.168.1.67/Multimedia`. Used to find an existing mount
    /// regardless of which directory NetFS chose for it.
    public var mountFromIdentifier: String {
        let host = url.host ?? ""
        let share = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "//\(username)@\(host)/\(share)"
    }
}
