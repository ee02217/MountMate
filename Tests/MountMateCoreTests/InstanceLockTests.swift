import Testing
import Foundation
@testable import MountMateCore

private func makeLockPath() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("instance.lock")
}

@Test func theFirstHolderAcquiresTheLock() throws {
    let path = try makeLockPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    #expect(InstanceLock(path: path) != nil)
}

@Test func aSecondHolderIsRefused() throws {
    let path = try makeLockPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    let first = InstanceLock(path: path)
    #expect(first != nil)

    // The whole point: a second copy of the app must not start and race the first
    // into a duplicate mount.
    #expect(InstanceLock(path: path) == nil)

    _ = first   // keep it alive until here
}

@Test func releasingLetsTheNextHolderIn() throws {
    let path = try makeLockPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

    do {
        let first = InstanceLock(path: path)
        #expect(first != nil)
    }   // released here

    #expect(InstanceLock(path: path) != nil)
}
