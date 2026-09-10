import Testing
import Foundation
@testable import MountMateCore

private func makeEndpoint() throws -> ShareEndpoint {
    try ShareEndpoint(
        displayName: "Multimedia",
        url: URL(string: "smb://192.168.1.67/Multimedia")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

private let ours = "//smbshare@192.168.1.67/Multimedia"

@Test func anEmptyMountTableHasNothingForTheEndpoint() throws {
    let partition = EndpointMounts.partition([], for: try makeEndpoint())
    #expect(partition.expected == nil)
    #expect(partition.strays.isEmpty)
}

@Test func aMountAtTheExpectedPathIsTheExpectedOne() throws {
    let partition = EndpointMounts.partition(
        [MountedVolume(from: ours, on: "/Volumes/Multimedia")], for: try makeEndpoint()
    )
    #expect(partition.expected == MountedVolume(from: ours, on: "/Volumes/Multimedia"))
    #expect(partition.strays.isEmpty)
}

@Test func aMountOfOurShareAtAnotherPathIsAStray() throws {
    let partition = EndpointMounts.partition(
        [MountedVolume(from: ours, on: "/Volumes/Multimedia-1")], for: try makeEndpoint()
    )
    #expect(partition.expected == nil)
    #expect(partition.strays == [MountedVolume(from: ours, on: "/Volumes/Multimedia-1")])
}

@Test func everyStrayIsReturnedNotJustTheFirst() throws {
    // `existingMount`'s `.first` is what made the 2026-09-10 cleanup take one pass
    // per stray. The incident left six.
    let volumes = (1...6).map { MountedVolume(from: ours, on: "/Volumes/Multimedia-\($0)") }
    let partition = EndpointMounts.partition(volumes, for: try makeEndpoint())

    #expect(partition.expected == nil)
    #expect(partition.strays.count == 6)
}

@Test func theExpectedMountAndItsStraysAreSeparated() throws {
    let volumes = [
        MountedVolume(from: ours, on: "/Volumes/Multimedia-1"),
        MountedVolume(from: ours, on: "/Volumes/Multimedia"),
        MountedVolume(from: ours, on: "/Volumes/Multimedia-2"),
    ]
    let partition = EndpointMounts.partition(volumes, for: try makeEndpoint())

    #expect(partition.expected?.on == "/Volumes/Multimedia")
    #expect(partition.strays.map(\.on) == ["/Volumes/Multimedia-1", "/Volumes/Multimedia-2"])
}

@Test func anotherSharesMountIsNeverOurs() throws {
    // A different share sitting on our expected path has a different `from`. It is an
    // obstruction, not a stray, and this type must not claim it — otherwise the sweep
    // would unmount somebody else's volume.
    let volumes = [
        MountedVolume(from: "//smbshare@192.168.1.67/Backups", on: "/Volumes/Multimedia"),
        MountedVolume(from: "//other@192.168.1.99/Multimedia", on: "/Volumes/Multimedia-1"),
    ]
    let partition = EndpointMounts.partition(volumes, for: try makeEndpoint())

    #expect(partition.expected == nil)
    #expect(partition.strays.isEmpty)
}
