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

// MARK: - The remedy a failure carries

@Test func theRemedyForALeftoverDirectoryNamesTheRealPath() throws {
    let failure = MountFailure(
        reason: .mountpointOccupied,
        obstruction: .emptyDirectory,
        path: "/Volumes/Multimedia"
    )
    let remedy = try #require(failure.remedy)
    #expect(remedy.contains("/Volumes/Multimedia"))
    #expect(remedy.contains("rmdir"))
}

@Test func theRemedyForADirectoryWithFilesDoesNotSuggestRmdir() throws {
    // `rmdir` fails on a non-empty directory. Suggesting it sends the user to a
    // command that cannot work and tells them nothing about why.
    let failure = MountFailure(
        reason: .mountpointOccupied,
        obstruction: .nonEmptyDirectory,
        path: "/Volumes/Multimedia"
    )
    let remedy = try #require(failure.remedy)
    #expect(!remedy.contains("rmdir"))
    #expect(remedy.contains("/Volumes/Multimedia"))
}

@Test func theRemedyForAnotherVolumeNamesIt() throws {
    let failure = MountFailure(
        reason: .mountpointOccupied,
        obstruction: .otherVolume(from: "//other@host/Thing"),
        path: "/Volumes/Multimedia"
    )
    #expect(try #require(failure.remedy).contains("//other@host/Thing"))
}

@Test func aFailureWithNoObstructionFallsBackToItsReasonsRemedy() {
    // `DiagnosticsReport` reads `MountFailureReason.mountpointOccupied.remedy`
    // statically, with no failure in hand. That must keep working.
    let failure = MountFailure(reason: .mountpointOccupied)
    #expect(failure.remedy == MountFailureReason.mountpointOccupied.remedy)
    #expect(MountFailure(reason: .hostUnreachable).remedy == nil)
}
