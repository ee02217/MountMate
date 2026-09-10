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
