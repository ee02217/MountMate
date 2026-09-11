import Foundation

/// Where activity is recorded.
public protocol ActivityLog: Sendable {
    func append(_ entry: ActivityEntry) async
    /// Most recent first, at most `limit` entries.
    func recent(limit: Int) async -> [ActivityEntry]
}

/// The activity log, as a trimmed file beside `endpoints.json`.
///
/// A file rather than an in-memory buffer: the failures worth reading
/// about happen overnight, and a log that dies with the process cannot answer the
/// question the pane is opened to ask.
public actor FileActivityLog: ActivityLog {
    /// `nonisolated` so callers can read the path without awaiting the actor — it is
    /// an immutable `Sendable` value fixed at init, and awaiting it would be a
    /// suspension point that buys nothing.
    public nonisolated let fileURL: URL
    private let maximumLines: Int

    public init(directory: URL, maximumLines: Int = 2000) {
        self.fileURL = directory.appendingPathComponent("activity.log")
        self.maximumLines = maximumLines
    }

    public func append(_ entry: ActivityEntry) async {
        var lines = readLines()
        lines.append(Self.encode(entry))
        // Trim from the front: the newest entries are the ones worth keeping.
        if lines.count > maximumLines {
            lines = Array(lines.suffix(maximumLines))
        }
        write(lines)
    }

    public func recent(limit: Int) async -> [ActivityEntry] {
        readLines()
            .reversed()
            .prefix(limit)
            .compactMap(Self.decode)
    }

    private func readLines() -> [String] {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func write(_ lines: [String]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic for the same reason `endpoints.json` is: a truncated log is a lost
        // log, and this file exists precisely for the moments things go wrong.
        try? Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: fileURL, options: .atomic)
    }

    /// Tab-separated so the file stays greppable by hand, which is half the point of
    /// putting it on disk.
    private static func encode(_ entry: ActivityEntry) -> String {
        let stamp = ISO8601DateFormatter().string(from: entry.timestamp)
        return "\(stamp)\t\(entry.category.rawValue)\t\(entry.share ?? "")\t\(entry.message)"
    }

    private static func decode(_ line: String) -> ActivityEntry? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let date = ISO8601DateFormatter().date(from: String(parts[0])),
              let category = ActivityCategory(rawValue: String(parts[1]))
        else { return nil }

        let share = parts[2].isEmpty ? nil : String(parts[2])
        return ActivityEntry(
            timestamp: date, category: category, share: share, message: String(parts[3])
        )
    }
}
