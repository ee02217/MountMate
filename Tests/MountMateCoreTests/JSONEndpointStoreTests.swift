import Testing
import Foundation
@testable import MountMateCore

func makeStoreEndpoint(
    id: UUID = UUID(),
    name: String = "Multimedia",
    host: String = "192.168.1.67"
) throws -> ShareEndpoint {
    try ShareEndpoint(
        id: id,
        displayName: name,
        url: URL(string: "smb://\(host)/\(name)")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

@Test func anEmptyLoadCarriesNothing() {
    let load = EndpointLoad.empty
    #expect(load.endpoints.isEmpty)
    #expect(load.skipped.isEmpty)
    #expect(load.quarantined == nil)
}

@Test func theInMemoryStoreRoundTrips() async throws {
    let store = InMemoryEndpointStore()
    let endpoint = try makeStoreEndpoint()

    try await store.save([endpoint])
    let load = try await store.load()

    #expect(load.endpoints == [endpoint])
    #expect(load.skipped.isEmpty)
}
