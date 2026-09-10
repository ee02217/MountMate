import Testing
import Foundation
@testable import MountMateCore

@Test func enumeratesTheRootVolume() async {
    let inspector = SystemMountInspector()
    let volumes = await inspector.mountedVolumes()
    // Every Mac has a root filesystem; this asserts we parsed the table at all.
    #expect(volumes.contains { $0.on == "/" })
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
