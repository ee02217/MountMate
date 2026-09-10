import Testing
import Foundation
@testable import MountMateCore

@Test func volumesPolicyExpectsTheShareNameUnderVolumes() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia")
    #expect(ExpectedMountpoint.path(for: endpoint) == "/Volumes/Multimedia")
}

@Test func aCustomPolicyNamesItsOwnPath() throws {
    var endpoint = try makeStoreEndpoint(name: "Multimedia")
    endpoint.mountPolicy = .custom(path: "/Users/me/mnt/media")
    #expect(ExpectedMountpoint.path(for: endpoint) == "/Users/me/mnt/media")
}

@Test func theExpectedPathMatchesItself() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia")
    #expect(ExpectedMountpoint.matches("/Volumes/Multimedia", for: endpoint))
}

/// The failure that took Plex offline: NetFS picks `<name>-1` when the expected
/// mountpoint is occupied, and the engine recorded it as success.
@Test func aSuffixedPathDoesNotMatch() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia")
    #expect(!ExpectedMountpoint.matches("/Volumes/Multimedia-1", for: endpoint))
    #expect(!ExpectedMountpoint.matches("/Volumes/Multimedia-2", for: endpoint))
}

/// A trailing slash is the same place, and must not be read as a mismatch — that
/// would unmount a perfectly good mount.
@Test func aTrailingSlashIsStillAMatch() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia")
    #expect(ExpectedMountpoint.matches("/Volumes/Multimedia/", for: endpoint))
}

/// A different share entirely is obviously not a match.
@Test func anUnrelatedPathDoesNotMatch() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia")
    #expect(!ExpectedMountpoint.matches("/Volumes/Backup", for: endpoint))
}
