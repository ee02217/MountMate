import Foundation

/// Keeps a share's password reachable when the share is edited.
///
/// The Keychain item is keyed on server + account + protocol + path (spec §5.6), so
/// correcting a hostname changes the key and orphans the password — the share then
/// reports "No password saved" for a reason nobody can see. There is no rename in
/// the Keychain API, so a move is read, write, delete.
public struct CredentialMover: Sendable {
    private let store: any CredentialStore

    public init(store: any CredentialStore) {
        self.store = store
    }

    /// Applies whatever this save should do to the stored password.
    ///
    /// `old` is nil for a share being created. A typed password always wins: someone
    /// who typed one meant it, whatever was stored before.
    public func settle(
        draft: ShareDraft,
        old: ShareEndpoint?,
        new: ShareEndpoint
    ) async throws {
        let identityChanged = old.map { !Self.sameIdentity($0, new) } ?? false

        // Carry the existing password across before anything is deleted.
        var carried: String?
        if identityChanged, let old {
            carried = await store.password(for: old)
        }

        if let typed = draft.password, !typed.isEmpty {
            try await store.setPassword(typed, for: new)
        } else if let carried, !carried.isEmpty {
            try await store.setPassword(carried, for: new)
        }

        if identityChanged, let old {
            try await store.removePassword(for: old)
        }
    }

    /// Same Keychain key, in other words. Compares only the fields
    /// `KeychainQuery.attributes` reads.
    private static func sameIdentity(_ a: ShareEndpoint, _ b: ShareEndpoint) -> Bool {
        a.url.host == b.url.host
            && a.url.path == b.url.path
            && a.username == b.username
            && a.url.scheme?.lowercased() == b.url.scheme?.lowercased()
    }
}
