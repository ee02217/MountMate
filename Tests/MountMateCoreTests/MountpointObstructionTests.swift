import Testing
import Foundation
@testable import MountMateCore

@Test func aVolumeMountedAtTheExpectedPathObstructsIt() {
    let obstruction = MountpointObstruction.fromMountTable(
        expectedPath: "/Volumes/Multimedia",
        volumes: [MountedVolume(from: "//other@host/Thing", on: "/Volumes/Multimedia")]
    )
    #expect(obstruction == .otherVolume(from: "//other@host/Thing"))
}

@Test func anUnrelatedMountDoesNotObstruct() {
    // The mount table cannot decide; the caller must look at the filesystem.
    let obstruction = MountpointObstruction.fromMountTable(
        expectedPath: "/Volumes/Multimedia",
        volumes: [MountedVolume(from: "//other@host/Thing", on: "/Volumes/Thing")]
    )
    #expect(obstruction == nil)
}

@Test func anAbsentDirectoryLeavesTheMountpointClear() {
    #expect(MountpointObstruction.fromDirectory(.absent) == .clear)
}

@Test func anEmptyDirectoryObstructsTheMountpoint() {
    // The 2026-09-10 case. NetFS does not fail on this — it silently picks
    // `<name>-1`, which is precisely why it must be caught before mounting.
    #expect(MountpointObstruction.fromDirectory(.empty) == .emptyDirectory)
}

@Test func aNonEmptyDirectoryObstructsTheMountpoint() {
    #expect(MountpointObstruction.fromDirectory(.nonEmpty) == .nonEmptyDirectory)
}
