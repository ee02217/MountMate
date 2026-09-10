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

/// A fresh temp directory per test, removed when the test ends.
private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aMissingFileLoadsEmptyWithoutError() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    let load = try await store.load()

    // First run is not a failure.
    #expect(load.endpoints.isEmpty)
    #expect(load.skipped.isEmpty)
    #expect(load.quarantined == nil)
}

@Test func aWellFormedFileLoadsEveryEntry() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    let json = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "displayName": "Multimedia",
            "url": "smb://192.168.1.67/Multimedia",
            "username": "smbshare",
            "mountPolicy": { "volumes": {} },
            "enabled": true,
            "readOnly": false
          }
        ]
        """
    try Data(json.utf8).write(to: store.fileURL)

    let load = try await store.load()

    #expect(load.endpoints.count == 1)
    #expect(load.endpoints.first?.displayName == "Multimedia")
    #expect(load.skipped.isEmpty)
}
