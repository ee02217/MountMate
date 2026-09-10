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

@Test func anyFailureMakesTheIconAWarning() {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Multimedia", state: .mounted(path: "/Volumes/Multimedia")),
        makeStatus(name: "Backup", state: .failed(MountFailure(reason: .hostUnreachable))),
    ])
    #expect(presentation.iconSymbolName == "externaldrive.badge.exclamationmark")
}

@Test func allMountedMakesTheIconACheckmark() {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Multimedia", state: .mounted(path: "/Volumes/Multimedia")),
        makeStatus(name: "Backup", state: .mounted(path: "/Volumes/Backup")),
    ])
    #expect(presentation.iconSymbolName == "externaldrive.badge.checkmark")
}

/// A disabled endpoint is not a problem, so it must not raise the warning icon.
@Test func disabledEndpointsDoNotWarn() {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Multimedia", state: .mounted(path: "/Volumes/Multimedia")),
        makeStatus(name: "Backup", state: .idle, enabled: false),
    ])
    #expect(presentation.iconSymbolName == "externaldrive.badge.checkmark")
}

@Test func nothingConfiguredIsAPlainIcon() {
    #expect(MenuPresentation(statuses: []).iconSymbolName == "externaldrive")
}

@Test func aMountedRowShowsItsPathAndOffersUnmount() throws {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Multimedia", state: .mounted(path: "/Volumes/Multimedia"))
    ])
    let row = try #require(presentation.rows.first)

    #expect(row.title == "Multimedia")
    #expect(row.subtitle == "/Volumes/Multimedia")
    #expect(row.dot == .mounted)
    #expect(row.actionTitle == "Unmount")
}

@Test func aDisabledRowOffersToMountAndSaysWhyItIsIdle() throws {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Backup", state: .idle, enabled: false)
    ])
    let row = try #require(presentation.rows.first)

    #expect(row.dot == .disabled)
    #expect(row.subtitle == "Disabled")
    #expect(row.actionTitle == "Mount")
}

@Test func aFailedRowNamesTheReason() throws {
    let presentation = MenuPresentation(statuses: [
        makeStatus(name: "Backup", state: .failed(MountFailure(reason: .hostUnreachable)))
    ])
    let row = try #require(presentation.rows.first)

    #expect(row.dot == .failed)
    #expect(row.subtitle == "Host unreachable")
    #expect(row.actionTitle == "Retry")
}
