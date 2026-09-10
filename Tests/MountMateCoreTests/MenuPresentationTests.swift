import Testing
import Foundation
@testable import MountMateCore

func makeStatus(
    name: String = "Multimedia",
    state: MountState = .idle,
    enabled: Bool = true
) -> EndpointStatus {
    EndpointStatus(
        id: UUID(),
        displayName: name,
        state: state,
        enabled: enabled
    )
}

@Test func aMountedStatusExposesItsPath() {
    let status = makeStatus(state: .mounted(path: "/Volumes/Multimedia"))
    #expect(status.mountPath == "/Volumes/Multimedia")
}

@Test func aStatusWithNowhereMountedHasNoPath() {
    #expect(makeStatus(state: .idle).mountPath == nil)
    #expect(makeStatus(state: .mounting).mountPath == nil)
    #expect(makeStatus(state: .failed(MountFailure(reason: .hostUnreachable))).mountPath == nil)
}

/// A stale mount is still attached, so it still has a path worth revealing — the
/// engine is about to force-unmount and remount it, not detach it.
@Test func aStaleStatusStillExposesItsPath() {
    let status = makeStatus(state: .stale(path: "/Volumes/Multimedia"))
    #expect(status.mountPath == "/Volumes/Multimedia")
}
