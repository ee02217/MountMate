import Foundation

/// How tightly the stored password is bound to this application.
///
/// In practice `.permissive` is the only reachable value (spec §6.1). Restricting a
/// Keychain item to one application requires `SecAccessCreate` and
/// `SecTrustedApplicationCreateFromPath` — deprecated since 10.10 — or
/// `kSecAttrAccessGroup`, which needs a paid Apple team identifier. The self-signed
/// identity milestone 7a introduces gives a stable designated requirement, which is
/// what `SMAppService` needs for launch-at-login, but it does not unlock an
/// app-restricted ACL.
///
/// `.appRestricted` stays defined because the distinction is real and the Diagnostics
/// pane reports which is in force; it becomes reachable if this app ever ships with a
/// team identifier.
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
