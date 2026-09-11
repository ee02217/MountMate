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

@Test func theFakeReportsTheConservativePolicy() async {
    let store = InMemoryCredentialStore()
    #expect(await store.accessPolicy == .buildBound)
}

@Test func theQueryIsAGenericPasswordUnderMountMatesOwnService() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia", host: "192.168.1.67")
    let attributes = KeychainQuery.attributes(for: endpoint)

    // Generic, not internet: an internet password keyed on server+account+protocol
    // collides with the credential Finder and NetFS rely on. MountMate lost one that
    // way on 2026-09-10 (spec §9.1).
    #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(attributes[kSecAttrService as String] as? String == "com.sergio.mountmate")

    // The account still identifies the share unambiguously.
    let account = try #require(attributes[kSecAttrAccount as String] as? String)
    #expect(account.contains("192.168.1.67"))
    #expect(account.contains("Multimedia"))
    #expect(account.contains("smbshare"))
}

@Test func twoSharesOnOneServerGetDifferentAccounts() throws {
    let first = try makeStoreEndpoint(name: "Multimedia", host: "192.168.1.67")
    let second = try makeStoreEndpoint(name: "Backup", host: "192.168.1.67")

    let a = KeychainQuery.attributes(for: first)[kSecAttrAccount as String] as? String
    let b = KeychainQuery.attributes(for: second)[kSecAttrAccount as String] as? String
    #expect(a != b)
}

@Test func theQueryNeverUsesTheInternetPasswordClass() throws {
    let endpoint = try makeStoreEndpoint()
    let attributes = KeychainQuery.attributes(for: endpoint)

    // The shape that caused the collision must not be reachable at all.
    #expect(attributes[kSecClass as String] as? String != kSecClassInternetPassword as String)
    #expect(attributes[kSecAttrServer as String] == nil)
    #expect(attributes[kSecAttrPath as String] == nil)
}

/// The query must not carry the secret: the password is a separate parameter on the
/// add/update call so it never becomes a lookup key.
@Test func theQueryCarriesNoPassword() throws {
    let endpoint = try makeStoreEndpoint()
    let attributes = KeychainQuery.attributes(for: endpoint)

    #expect(attributes[kSecValueData as String] == nil)
}

@Test(.enabled(if: keychainIsAvailable))
func theKeychainStoreRoundTripsAPassword() async throws {
    let store = KeychainCredentialStore()
    let endpoint = try makeStoreEndpoint(
        name: "MountMateTest",
        host: "mountmate-test.invalid"
    )
    // Leave no item behind even if an assertion fails partway.
    try? await store.removePassword(for: endpoint)

    try await store.setPassword("hunter2", for: endpoint)
    #expect(await store.password(for: endpoint) == "hunter2")

    // Setting again must update in place, not fail as a duplicate.
    try await store.setPassword("hunter3", for: endpoint)
    #expect(await store.password(for: endpoint) == "hunter3")

    try await store.removePassword(for: endpoint)
    #expect(await store.password(for: endpoint) == nil)
}

@Test(.enabled(if: keychainIsAvailable))
func removingAnAbsentPasswordIsNotAnError() async throws {
    let store = KeychainCredentialStore()
    let endpoint = try makeStoreEndpoint(
        name: "MountMateAbsent",
        host: "mountmate-absent.invalid"
    )

    // errSecItemNotFound is the expected state, not a failure to report.
    try await store.removePassword(for: endpoint)
}

/// No Keychain access needed: the policy follows from how the running app is
/// signed, which is injected here rather than read from the test runner's own
/// signature.
@Test func theKeychainStoreReportsThePolicyItsSigningTeamImplies() async {
    let teamSigned = KeychainCredentialStore(teamIdentifier: { "GLS94R3UX4" })
    #expect(await teamSigned.accessPolicy == .appRestricted)

    let selfSigned = KeychainCredentialStore(teamIdentifier: { nil })
    #expect(await selfSigned.accessPolicy == .buildBound)
}
