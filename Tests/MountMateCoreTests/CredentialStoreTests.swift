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
