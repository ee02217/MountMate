import Testing
import Foundation
@testable import MountMateCore

@Test func enumeratesTheRootVolume() async {
    let inspector = SystemMountInspector()
    let volumes = await inspector.mountedVolumes()
    // Every Mac has a root filesystem; this asserts we parsed the table at all.
    #expect(volumes.contains { $0.on == "/" })
}

@Test func concurrentMountTableReadsAreSafe() async {
    // `getmntinfo` owns its results buffer and is not thread-safe: a second caller can
    // free or overwrite the buffer the first is still reading. `MountInspector` is
    // `Sendable`, so concurrent callers are permitted by the type — `getmntinfo_r_np`
    // is what makes that promise true. Under the old call this is the shape that
    // corrupts (and it would corrupt under ASan/TSan long before it produced a wrong
    // answer here).
    let inspector = SystemMountInspector()
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<32 {
            group.addTask { await inspector.mountedVolumes().contains { $0.on == "/" } }
        }
        for await sawRoot in group {
            #expect(sawRoot)
        }
    }
}

@Test func rootVolumeIsResponsive() async {
    let inspector = SystemMountInspector()
    #expect(await inspector.isResponsive(path: "/") == true)
}

@Test func nonexistentPathIsNotResponsive() async {
    let inspector = SystemMountInspector()
    #expect(await inspector.isResponsive(path: "/definitely/not/here/xyz") == false)
}

@Test func nonexistentPathRespondsPromptly() async {
    // Pins the fast path: statfs on a nonexistent path fails immediately (ENOENT),
    // so this must return well under the 10s timeout bound. If a future change made
    // the timeout the only exit, this test would catch it by timing out itself.
    let inspector = SystemMountInspector()
    let clock = ContinuousClock()
    let start = clock.now
    let result = await inspector.isResponsive(path: "/definitely/not/here/xyz")
    let elapsed = clock.now - start
    #expect(result == false)
    #expect(elapsed < .seconds(5))
}

@Test func aWedgedPathIsProbedOnceAndThenShortCircuited() async {
    // The leak this closes: a probe that times out strands its worker thread forever.
    // With the 5-minute backstop sweep re-probing, a permanently wedged mount would
    // strand ~288 threads a day on a machine meant to run unattended for months, and
    // the eventual failure is process death. So it must be probed once, not once per
    // health check.
    let probe = HangingProbe()
    let registry = WedgedPathRegistry()
    let inspector = SystemMountInspector(
        probeTimeout: .milliseconds(150),
        wedgedPaths: registry,
        probe: { probe($0) }
    )
    let path = "/Volumes/definitely-not-real-wedged"

    #expect(await inspector.isResponsive(path: path) == false)
    #expect(probe.entries == 1)

    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<5 {
        #expect(await inspector.isResponsive(path: path) == false)
    }
    let elapsed = clock.now - start

    // No new threads, and no waiting on a deadline that is already known to expire.
    #expect(probe.entries == 1)
    #expect(elapsed < .milliseconds(150))
    #expect(await registry.isRecorded(path: path))

    probe.release()
}

@Test func aSuccessfulProbeLeavesNothingRecorded() async {
    let registry = WedgedPathRegistry()
    let inspector = SystemMountInspector(
        probeTimeout: .seconds(5),
        wedgedPaths: registry,
        probe: { _ in true }
    )

    #expect(await inspector.isResponsive(path: "/") == true)
    #expect(await registry.isRecorded(path: "/") == false)
}

// MARK: - WedgedPathRegistry

@Test func registryShortCircuitsWhileTheMountIsUnchanged() async {
    let registry = WedgedPathRegistry()
    await registry.recordWedged(path: "/Volumes/M", from: "//u@h/M")

    #expect(await registry.shouldShortCircuit(path: "/Volumes/M", currentFrom: "//u@h/M"))
}

@Test func registryReArmsWhenTheMountTableEntryChanges() async {
    let registry = WedgedPathRegistry()
    await registry.recordWedged(path: "/Volumes/M", from: "//u@h/M")

    // A different share is now mounted there: whatever was wedged is gone.
    #expect(await registry.shouldShortCircuit(path: "/Volumes/M", currentFrom: "//u@h2/M") == false)
    #expect(await registry.isRecorded(path: "/Volumes/M") == false)
}

@Test func registryReArmsWhenTheMountDisappears() async {
    let registry = WedgedPathRegistry()
    await registry.recordWedged(path: "/Volumes/M", from: "//u@h/M")

    #expect(await registry.shouldShortCircuit(path: "/Volumes/M", currentFrom: nil) == false)
    #expect(await registry.isRecorded(path: "/Volumes/M") == false)
}

@Test func registryIgnoresPathsItHasNeverSeen() async {
    let registry = WedgedPathRegistry()
    #expect(await registry.shouldShortCircuit(path: "/Volumes/M", currentFrom: nil) == false)
}

// MARK: - Directory state

@Test func anAbsentPathHasNoDirectoryState() async {
    let inspector = SystemMountInspector()
    #expect(await inspector.directoryState(at: "/definitely/not/here/xyz") == .absent)
}

@Test func anEmptyDirectoryIsReportedEmpty() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let inspector = SystemMountInspector()
    #expect(await inspector.directoryState(at: directory.path) == .empty)
}

@Test func aDirectoryWithContentIsReportedNonEmpty() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-full-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: directory.appendingPathComponent("file.txt"))
    defer { try? FileManager.default.removeItem(at: directory) }

    let inspector = SystemMountInspector()
    #expect(await inspector.directoryState(at: directory.path) == .nonEmpty)
}

@Test func aFileWhereADirectoryWasExpectedReadsAsAbsent() async throws {
    // NetFS will fail on this, and there is nothing this app can tell the user to do
    // about it that it could not tell them about any other mount failure. Folding it
    // into `.absent` keeps the obstruction vocabulary to cases with distinct remedies.
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-file-\(UUID().uuidString)")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let inspector = SystemMountInspector()
    #expect(await inspector.directoryState(at: file.path) == .absent)
}
