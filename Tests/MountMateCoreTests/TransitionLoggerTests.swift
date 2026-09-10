import Testing
import Foundation
@testable import MountMateCore

@Test func anEntryFormatsAsTimeThenShareThenMessage() {
    let entry = ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 0),
        category: .mount,
        share: "Multimedia",
        message: "mounted /Volumes/Multimedia"
    )
    let line = entry.formatted()

    #expect(line.contains("Multimedia"))
    #expect(line.contains("mounted /Volumes/Multimedia"))
    // A log read at a glance needs the time first.
    #expect(line.hasPrefix("1970-01-01"))
}

@Test func anEntryWithNoShareOmitsTheField() {
    let entry = ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 0),
        category: .lifecycle,
        share: nil,
        message: "started"
    )
    #expect(entry.formatted().hasSuffix("started"))
}

@Test func theInMemoryLogReturnsMostRecentFirst() async {
    let log = InMemoryActivityLog()
    await log.append(ActivityEntry(timestamp: Date(timeIntervalSince1970: 1), category: .lifecycle, share: nil, message: "first"))
    await log.append(ActivityEntry(timestamp: Date(timeIntervalSince1970: 2), category: .lifecycle, share: nil, message: "second"))

    let recent = await log.recent(limit: 10)
    #expect(recent.map(\.message) == ["second", "first"])
}

private func status(
    _ name: String,
    _ state: MountState,
    id: UUID,
    enabled: Bool = true
) -> EndpointStatus {
    EndpointStatus(id: id, displayName: name, state: state, enabled: enabled)
}

@Test func anUnchangedSnapshotProducesNothing() {
    let id = UUID()
    let snapshot = [status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: id)]

    let entries = TransitionLogger.entries(from: snapshot, to: snapshot, at: Date())

    // The backstop sweeps every five minutes; logging each one would bury the
    // single line that explains an outage.
    #expect(entries.isEmpty)
}

@Test func aFirstSnapshotLogsEveryShare() {
    let entries = TransitionLogger.entries(
        from: nil,
        to: [
            status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: UUID()),
            status("Backup", .failed(MountFailure(reason: .hostUnreachable)), id: UUID()),
        ],
        at: Date()
    )
    #expect(entries.count == 2)
}

@Test func aFailureNamesItsReason() {
    let id = UUID()
    let entries = TransitionLogger.entries(
        from: [status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: id)],
        to: [status("Multimedia", .failed(MountFailure(reason: .hostUnreachable)), id: id)],
        at: Date()
    )

    #expect(entries.count == 1)
    #expect(entries[0].share == "Multimedia")
    #expect(entries[0].category == .mount)
    #expect(entries[0].message.contains("host unreachable"))
}

@Test func recoveryIsLogged() {
    let id = UUID()
    let entries = TransitionLogger.entries(
        from: [status("Multimedia", .failed(MountFailure(reason: .hostUnreachable)), id: id)],
        to: [status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: id)],
        at: Date()
    )

    #expect(entries.count == 1)
    #expect(entries[0].message.contains("/Volumes/Multimedia"))
}

/// A share added while running has no previous state; it must still be logged.
@Test func aNewShareIsLoggedOnItsFirstAppearance() {
    let existing = UUID()
    let added = UUID()
    let entries = TransitionLogger.entries(
        from: [status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: existing)],
        to: [
            status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: existing),
            status("Backup", .mounting, id: added),
        ],
        at: Date()
    )

    #expect(entries.count == 1)
    #expect(entries[0].share == "Backup")
}

/// A share removed in Settings should not produce a phantom entry.
@Test func aRemovedShareProducesNothing() {
    let kept = UUID()
    let removed = UUID()
    let entries = TransitionLogger.entries(
        from: [
            status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: kept),
            status("Backup", .mounted(path: "/Volumes/Backup"), id: removed),
        ],
        to: [status("Multimedia", .mounted(path: "/Volumes/Multimedia"), id: kept)],
        at: Date()
    )

    #expect(entries.isEmpty)
}
