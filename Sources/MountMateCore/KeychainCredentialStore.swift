import Foundation
import Security

/// Builds the attribute dictionary identifying one endpoint's Keychain item.
///
/// Keyed on server + account + protocol + path, which is the shape macOS itself uses
/// for network shares (spec §5.6) — so the items read sensibly in Keychain Access
/// rather than appearing as opaque blobs. Pure, so the keying rule is testable
/// without a Keychain, which matters because the Keychain is unreachable from any
/// process outside the user's GUI session.
enum KeychainQuery {
    static func attributes(for endpoint: ShareEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword as String,
            kSecAttrServer as String: endpoint.url.host ?? "",
            kSecAttrAccount as String: endpoint.username,
            kSecAttrPath as String: endpoint.url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            kSecAttrProtocol as String: protocolAttribute(for: endpoint) as String,
        ]
    }

    private static func protocolAttribute(for endpoint: ShareEndpoint) -> CFString {
        // `ShareEndpoint` refuses every scheme but these two, so the default is
        // unreachable today; it exists so adding a scheme there fails loudly here
        // rather than silently filing items under the wrong protocol.
        switch endpoint.url.scheme?.lowercased() {
        case "afp": return kSecAttrProtocolAFP
        default: return kSecAttrProtocolSMB
        }
    }
}

/// Passwords, in the login Keychain.
///
/// The password reaches `NetFSMountURLSync` as its `passwd` parameter and is never
/// embedded in a URL, so it never appears in a process listing (spec §5.6).
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    /// Always `.permissive`: see `CredentialAccessPolicy` and spec §6.1 for why an
    /// app-restricted ACL is not reachable without a paid team identifier. Reported
    /// rather than hidden, because §6 requires the boundary to be visible.
    public var accessPolicy: CredentialAccessPolicy {
        get async { .permissive }
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
