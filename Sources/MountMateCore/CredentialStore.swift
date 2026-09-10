import Foundation

/// How tightly the stored password is bound to this application.
///
/// Spec §6: a Keychain ACL binds to the code-signing identity, and an ad-hoc
/// signature's identity changes on every rebuild — so an app-restricted ACL would
/// make macOS treat the app as a stranger after each upgrade and raise an
/// authorization prompt. On a headless Mac that is the same class of bug the whole
/// project exists to close, so until milestone 7 provides a stable self-signed
/// identity the policy is `.permissive` and the app says so out loud.
public enum CredentialAccessPolicy: Sendable, Equatable {
    /// Readable by any process running as this user — the same trust boundary as a
    /// mode-600 file. Must be surfaced to the user, never left silent.
    case permissive
    /// Readable only by this application. Requires a stable signing identity.
    case appRestricted
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
