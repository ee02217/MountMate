import Foundation
import Security

/// Builds the attribute dictionary identifying one endpoint's Keychain item.
///
/// A **generic** password under MountMate's own service, not an internet password
/// (spec §9.1). Internet passwords are keyed on server + account + protocol + path,
/// which is the same space Finder and NetFS use — and macOS leaves `path` empty while
/// this app filled it in, so MountMate's items were invisible to the system while its
/// writes and deletes could still land on the system's. A working credential was lost
/// that way, and every mount afterwards fell back to an authentication dialog.
///
/// The cost is accepted: MountMate cannot reuse a password already saved in Finder,
/// so it must be entered once in Settings. In exchange it cannot damage one.
enum KeychainQuery {
    static let service = "com.sergio.mountmate"

    static func attributes(for endpoint: ShareEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: endpoint),
        ]
    }

    /// Identifies the share within MountMate's own namespace. Includes the scheme so
    /// the same share reached over smb and afp are distinct entries.
    static func account(for endpoint: ShareEndpoint) -> String {
        let scheme = endpoint.url.scheme?.lowercased() ?? "smb"
        let host = endpoint.url.host ?? ""
        let share = endpoint.url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme)://\(endpoint.username)@\(host)/\(share)"
    }
}

/// Passwords, in the login Keychain.
///
/// The password reaches `NetFSMountURLSync` as its `passwd` parameter and is never
/// embedded in a URL, so it never appears in a process listing (spec §5.6).
public struct KeychainCredentialStore: CredentialStore {
    private let teamIdentifier: @Sendable () -> String?

    /// `teamIdentifier` defaults to the running app's own signature; tests inject it,
    /// because the test runner's signature says nothing about MountMate's.
    public init(
        teamIdentifier: @escaping @Sendable () -> String? = CodeSignature.currentTeamIdentifier
    ) {
        self.teamIdentifier = teamIdentifier
    }

    /// Follows from how this app is signed, not from anything set on the item: the
    /// default partition macOS assigns is what decides who reads without a prompt.
    public var accessPolicy: CredentialAccessPolicy {
        get async { CredentialAccessPolicy(teamIdentifier: teamIdentifier()) }
    }

    public func password(for endpoint: ShareEndpoint) async -> String? {
        var query = KeychainQuery.attributes(for: endpoint)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for endpoint: ShareEndpoint) async throws {
        let query = KeychainQuery.attributes(for: endpoint)
        let secret = Data(password.utf8)

        // Try update first: SecItemAdd on an existing item returns errSecDuplicateItem,
        // and changing a password is at least as common as setting one.
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(update)
        }

        var insert = query
        insert[kSecValueData as String] = secret
        // Available after first unlock, and never synced to iCloud: this password is
        // for one NAS on one LAN, and syncing it would widen the blast radius for no
        // benefit.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(add)
        }
    }

    public func removePassword(for endpoint: ShareEndpoint) async throws {
        let status = SecItemDelete(KeychainQuery.attributes(for: endpoint) as CFDictionary)
        // Absent is the desired end state, so "not found" is success.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }
}
