import Foundation
import Security
@testable import MountMateCore

/// Whether this process can reach the login Keychain at all.
///
/// It cannot when the process is outside the user's GUI session — a sandboxed agent,
/// a CI runner, a launchd daemon all get `errSecNotAvailable` or an interaction
/// error rather than a prompt. Tests that need a real Keychain are gated on this so
/// they skip in those environments instead of failing, while still running for a
/// developer on their own Mac.
let keychainIsAvailable: Bool = {
    let probe = try! ShareEndpoint(
        displayName: "probe",
        url: URL(string: "smb://mountmate-probe.invalid/probe")!,
        username: "probe",
        mountPolicy: .volumes
    )

    // The probe must be a *write*. Reading an absent item returns errSecItemNotFound
    // even in a process that is forbidden to write, so a read proves nothing — a
    // non-GUI process gets that far and then fails the add with
    // errSecInteractionNotAllowed (-25308).
    var insert = KeychainQuery.attributes(for: probe)
    insert[kSecValueData as String] = Data("probe".utf8)
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let add = SecItemAdd(insert as CFDictionary, nil)
    let usable = (add == errSecSuccess || add == errSecDuplicateItem)
    if usable {
        _ = SecItemDelete(KeychainQuery.attributes(for: probe) as CFDictionary)
    }
    return usable
}()

/// An endpoint store with no filesystem behind it.
actor InMemoryEndpointStore: EndpointStore {
    private var endpoints: [ShareEndpoint]

    init(endpoints: [ShareEndpoint] = []) { self.endpoints = endpoints }

    func load() async throws -> EndpointLoad { EndpointLoad(endpoints: endpoints) }
    func save(_ endpoints: [ShareEndpoint]) async throws { self.endpoints = endpoints }
}

/// A credential store with no Keychain behind it.
actor InMemoryCredentialStore: CredentialStore {
    private var passwords: [UUID: String] = [:]

    var accessPolicy: CredentialAccessPolicy { .permissive }

    func password(for endpoint: ShareEndpoint) async -> String? {
        passwords[endpoint.id]
    }

    func setPassword(_ password: String, for endpoint: ShareEndpoint) async throws {
        passwords[endpoint.id] = password
    }

    func removePassword(for endpoint: ShareEndpoint) async throws {
        passwords.removeValue(forKey: endpoint.id)
    }
}
