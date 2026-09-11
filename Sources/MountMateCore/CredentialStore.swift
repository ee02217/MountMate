import Foundation

/// Who can read a stored password without macOS asking first.
///
/// Neither case is "any process". macOS partitions every Keychain item by the code
/// that created it, and a process outside the partition gets a prompt rather than the
/// password. What varies is how stable the partition is:
///
/// - Signed with a developer team, the partition is the team, so every build MountMate
///   ships from that team reads the item silently.
/// - Without a team — ad-hoc, self-signed or unsigned — the partition is this binary's
///   cdhash, which changes on every rebuild. Each update is a stranger and prompts.
///
/// Both were established by experiment on 2026-09-11, not assumed: two binaries with
/// different cdhashes prompted, and the same pair signed with one team did not.
public enum CredentialAccessPolicy: Sendable, Equatable {
    /// Signed with a team: only MountMate reads the password without a prompt, and
    /// updates from the same team keep reading it.
    case appRestricted
    /// No team: the password is bound to this exact build, so every update asks for
    /// the login password. Must be surfaced — on an unattended Mac, a prompt nobody
    /// answers blocks every mount.
    case buildBound

    public init(teamIdentifier: String?) {
        if let teamIdentifier, !teamIdentifier.isEmpty {
            self = .appRestricted
        } else {
            self = .buildBound
        }
    }
}

public enum CredentialStoreError: Error, Equatable {
    /// A `SecItem` call returned something other than success or "not found".
    case unexpectedStatus(Int32)
}

/// Where passwords live. Never `endpoints.json`, and never a process argument.
public protocol CredentialStore: Sendable {
    /// The policy actually in force, for the UI to report.
    var accessPolicy: CredentialAccessPolicy { get async }

    func password(for endpoint: ShareEndpoint) async -> String?
    func setPassword(_ password: String, for endpoint: ShareEndpoint) async throws
    func removePassword(for endpoint: ShareEndpoint) async throws
}
