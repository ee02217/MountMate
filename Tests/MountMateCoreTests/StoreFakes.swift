import Foundation
@testable import MountMateCore

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
