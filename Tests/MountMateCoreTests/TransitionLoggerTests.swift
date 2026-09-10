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
