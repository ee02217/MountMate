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

@Test func anInvalidEntryIsSkippedAndTheRestSurvive() async throws {
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
          },
          {
            "id": "22222222-2222-2222-2222-222222222222",
            "displayName": "Exports",
            "url": "nfs://192.168.1.67/Exports",
            "username": "smbshare",
            "mountPolicy": { "volumes": {} },
            "enabled": true,
            "readOnly": false
          },
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "displayName": "Backup",
            "url": "smb://192.168.1.67/Backup",
            "username": "smbshare",
            "mountPolicy": { "volumes": {} },
            "enabled": true,
            "readOnly": false
          }
        ]
        """
    try Data(json.utf8).write(to: store.fileURL)

    let load = try await store.load()

    // One typo must not cost the other two shares.
    #expect(load.endpoints.map(\.displayName) == ["Multimedia", "Backup"])
    #expect(load.skipped.count == 1)
    #expect(load.skipped.first?.index == 1)
    #expect(load.skipped.first?.reason.contains("nfs") == true)
}

@Test func anEntryOfTheWrongShapeIsSkippedWithoutHanging() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    // A bare string where an object belongs. The container must still advance.
    let json = """
        [
          "not an endpoint at all",
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "displayName": "Backup",
            "url": "smb://192.168.1.67/Backup",
            "username": "smbshare",
            "mountPolicy": { "volumes": {} },
            "enabled": true,
            "readOnly": false
          }
        ]
        """
    try Data(json.utf8).write(to: store.fileURL)

    let load = try await store.load()

    #expect(load.endpoints.map(\.displayName) == ["Backup"])
    #expect(load.skipped.map(\.index) == [0])
}

@Test func anUnparseableFileIsMovedAsideNotOverwritten() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    let garbage = "{ this is not json at all"
    try Data(garbage.utf8).write(to: store.fileURL)

    let load = try await store.load()

    #expect(load.endpoints.isEmpty)
    let quarantined = try #require(load.quarantined)

    // The original content survives, untouched, somewhere findable.
    let preserved = try String(contentsOf: quarantined, encoding: .utf8)
    #expect(preserved == garbage)

    // And the original path is now clear, so the app can write a fresh config.
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
}

@Test func savedEndpointsLoadBackIdentically() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    let first = try makeStoreEndpoint(name: "Multimedia")
    let second = try makeStoreEndpoint(name: "Backup")
    try await store.save([first, second])

    let load = try await store.load()
    #expect(load.endpoints == [first, second])
    #expect(load.skipped.isEmpty)
}

@Test func savingNeverLeavesTheFilePartiallyWritten() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    try await store.save([try makeStoreEndpoint(name: "Multimedia")])
    let firstSize = try Data(contentsOf: store.fileURL).count

    // A second, larger save must replace the file wholesale, never append or truncate
    // in place — the file is always either the old config or the new one.
    try await store.save([
        try makeStoreEndpoint(name: "Multimedia"),
        try makeStoreEndpoint(name: "Backup"),
        try makeStoreEndpoint(name: "Archive"),
    ])
    let load = try await store.load()

    #expect(load.endpoints.count == 3)
    #expect(load.skipped.isEmpty)
    #expect(try Data(contentsOf: store.fileURL).count > firstSize)
}

@Test func noPasswordFieldIsEverWritten() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONEndpointStore(directory: directory)

    try await store.save([try makeStoreEndpoint()])
    let written = try String(contentsOf: store.fileURL, encoding: .utf8).lowercased()

    // Spec §5.5 and §5.6: the file must not be able to carry a secret.
    #expect(!written.contains("password"))
    #expect(!written.contains("passwd"))
    #expect(!written.contains("secret"))
}
