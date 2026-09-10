import Testing
import Foundation
@testable import MountMateCore

@Test func theInMemoryStoreRoundTripsAPassword() async throws {
    let store = InMemoryCredentialStore()
    let endpoint = try makeStoreEndpoint()

    #expect(await store.password(for: endpoint) == nil)

    try await store.setPassword("hunter2", for: endpoint)
    #expect(await store.password(for: endpoint) == "hunter2")

    try await store.removePassword(for: endpoint)
    #expect(await store.password(for: endpoint) == nil)
}

@Test func theFakeReportsAPolicyLikeTheRealStore() async {
    let store = InMemoryCredentialStore()
    #expect(await store.accessPolicy == .permissive)
}

@Test func theQueryIsKeyedTheWayMacOSKeysTheseItems() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia", host: "192.168.1.67")
    let attributes = KeychainQuery.attributes(for: endpoint)

    #expect(attributes[kSecClass as String] as? String == kSecClassInternetPassword as String)
    #expect(attributes[kSecAttrServer as String] as? String == "192.168.1.67")
    #expect(attributes[kSecAttrAccount as String] as? String == "smbshare")
    #expect(attributes[kSecAttrPath as String] as? String == "Multimedia")
    #expect(attributes[kSecAttrProtocol as String] as? String == kSecAttrProtocolSMB as String)
}

@Test func afpEndpointsGetTheAfpProtocolAttribute() throws {
    let endpoint = try ShareEndpoint(
        displayName: "Archive",
        url: URL(string: "afp://192.168.1.67/Archive")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
    let attributes = KeychainQuery.attributes(for: endpoint)

    #expect(attributes[kSecAttrProtocol as String] as? String == kSecAttrProtocolAFP as String)
}

/// The query must not carry the secret: the password is a separate parameter on the
/// add/update call so it never becomes a lookup key.
@Test func theQueryCarriesNoPassword() throws {
    let endpoint = try makeStoreEndpoint()
    let attributes = KeychainQuery.attributes(for: endpoint)

    #expect(attributes[kSecValueData as String] == nil)
}
