import Testing
import Foundation
@testable import MountMateCore

@Test func derivesMountFromIdentifierMatchingGetmntinfo() throws {
    let endpoint = ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
    // Must match what getmntinfo reports for this mount, verified on hardware:
    //   //smbshare@192.168.1.67/Multimedia
    #expect(endpoint.mountFromIdentifier == "//smbshare@192.168.1.67/Multimedia")
}

@Test func encodedEndpointNeverContainsACredential() throws {
    let endpoint = ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .custom(path: "/Users/me/mnt/media")
    )
    let data = try JSONEncoder().encode(endpoint)
    let json = String(decoding: data, as: UTF8.self).lowercased()
    #expect(!json.contains("password"))
    #expect(!json.contains("secret"))
}

@Test func roundTripsThroughCodable() throws {
    let endpoint = ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .custom(path: "/Users/me/mnt/media")
    )
    let data = try JSONEncoder().encode(endpoint)
    let decoded = try JSONDecoder().decode(ShareEndpoint.self, from: data)
    #expect(decoded == endpoint)
}
