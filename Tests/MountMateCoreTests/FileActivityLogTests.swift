import Testing
import Foundation
@testable import MountMateCore

private func makeLogDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mountmate-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func entriesSurviveANewLogInstance() async throws {
    let directory = try makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = FileActivityLog(directory: directory)
    await first.append(ActivityEntry(category: .lifecycle, share: nil, message: "started"))

    // The whole point: a mount that failed at 3am is still readable at 9am, after a
    // quit, a crash or a reboot.
    let second = FileActivityLog(directory: directory)
    let recent = await second.recent(limit: 10)

    #expect(recent.count == 1)
    #expect(recent[0].message == "started")
    #expect(recent[0].category == .lifecycle)
}

@Test func theLogIsTrimmedToItsMaximum() async throws {
    let directory = try makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = FileActivityLog(directory: directory, maximumLines: 10)
    for index in 1...25 {
        await log.append(ActivityEntry(category: .mount, share: "S", message: "entry \(index)"))
    }

    // No `await`: `fileURL` is a Sendable `let`, so awaiting it warns.
    let lines = try String(contentsOf: log.fileURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count <= 10)

    // Trimming keeps the newest, not the oldest.
    let recent = await log.recent(limit: 5)
    #expect(recent.first?.message == "entry 25")
}

@Test func recentReturnsNewestFirst() async throws {
    let directory = try makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = FileActivityLog(directory: directory)
    await log.append(ActivityEntry(category: .mount, share: "S", message: "one"))
    await log.append(ActivityEntry(category: .mount, share: "S", message: "two"))

    let recent = await log.recent(limit: 10)
    #expect(recent.map(\.message) == ["two", "one"])
}

@Test func aMissingLogFileReadsAsEmpty() async throws {
    let directory = try makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = FileActivityLog(directory: directory)
    #expect(await log.recent(limit: 10).isEmpty)
}
