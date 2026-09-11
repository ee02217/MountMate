import Testing
import Foundation
@testable import MountMateCore

private func makeEndpoint(
    url: String,
    username: String = "nasuser",
    policy: MountPolicy = .volumes
) throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: url)!,
        username: username,
        mountPolicy: policy
    )
}

@Test func derivesMountFromIdentifierMatchingGetmntinfo() throws {
    let endpoint = try makeEndpoint(url: "smb://192.0.2.10/Multimedia")
    // Must match what getmntinfo reports for this mount, verified on hardware:
    //   //nasuser@192.0.2.10/Multimedia
    #expect(endpoint.mountFromIdentifier == "//nasuser@192.0.2.10/Multimedia")
}

// MARK: - No credential ever reaches the URL

@Test func aPasswordInTheURLIsStrippedBeforeItCanBePersisted() throws {
    // The guard that matters. No credential may ever be persisted or placed in a
    // URL, and this type is encoded straight into endpoints.json — so the test has
    // to start from a URL that actually carries
    // a secret. (The previous version of this test grepped for the words "password"
    // and "secret" on an endpoint that never had one: it could not fail.)
    let endpoint = try makeEndpoint(
        url: "smb://nasuser:s3cr3t@192.0.2.10/Multimedia",
        policy: .custom(path: "/Users/me/mnt/media")
    )

    #expect(endpoint.url.password == nil)
    #expect(endpoint.url.user == nil)
    #expect(endpoint.url.absoluteString == "smb://192.0.2.10/Multimedia")

    let json = String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self)
    #expect(!json.contains("s3cr3t"))
    #expect(!json.lowercased().contains("password"))
}

@Test func aPasswordCannotBeSmuggledInThroughDecoding() throws {
    // endpoints.json is a plain file a user (or anything else) can edit, so decoding
    // re-runs the same validation rather than trusting what is on disk.
    let json = """
        {
          "id": "\(UUID().uuidString)",
          "displayName": "Multimedia",
          "url": "smb://nasuser:s3cr3t@192.0.2.10/Multimedia",
          "username": "nasuser",
          "mountPolicy": { "volumes": {} },
          "enabled": true,
          "readOnly": false
        }
        """
    let decoded = try JSONDecoder().decode(ShareEndpoint.self, from: Data(json.utf8))
    #expect(decoded.url.absoluteString == "smb://192.0.2.10/Multimedia")

    let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(!reencoded.contains("s3cr3t"))
}

// MARK: - Scheme restriction

@Test func acceptsTheSchemesWhoseMountIdentifierWeCanDerive() throws {
    #expect(try makeEndpoint(url: "smb://192.0.2.10/Multimedia").url.scheme == "smb")
    #expect(try makeEndpoint(url: "afp://192.0.2.10/Multimedia").url.scheme == "afp")
    // Case is normalised rather than rejected.
    #expect(try makeEndpoint(url: "SMB://192.0.2.10/Multimedia").url.scheme == "smb")
}

@Test func rejectsSchemesWhoseMountIdentifierWouldNeverMatch() {
    // `mountFromIdentifier` only produces the SMB/AFP `//user@host/share` form. NFS
    // reports `host:/export`; an NFS endpoint would therefore never match its own
    // mount, so the engine would remount on every trigger — `<name>-1`, `<name>-2`, …
    // on a 5-minute timer. Closing the door explicitly beats a silent trap.
    for url in ["nfs://192.0.2.10/export", "https://dav.example.com/share", "ftp://h/s"] {
        #expect(throws: ShareEndpointError.self) {
            try makeEndpoint(url: url)
        }
    }
}

@Test func rejectsAURLWithNoHost() {
    // Previously produced a malformed identifier of the form `//nasuser@/Multimedia`.
    #expect(throws: ShareEndpointError.missingHost) {
        try makeEndpoint(url: "smb:///Multimedia")
    }
}

@Test func rejectsAURLWithNoShare() {
    #expect(throws: ShareEndpointError.missingShare) {
        try makeEndpoint(url: "smb://192.0.2.10")
    }
}

@Test func roundTripsThroughCodable() throws {
    let endpoint = try makeEndpoint(
        url: "smb://192.0.2.10/Multimedia",
        policy: .custom(path: "/Users/me/mnt/media")
    )
    let data = try JSONEncoder().encode(endpoint)
    let decoded = try JSONDecoder().decode(ShareEndpoint.self, from: data)
    #expect(decoded == endpoint)
}
