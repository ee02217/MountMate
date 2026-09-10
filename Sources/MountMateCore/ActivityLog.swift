import Foundation

/// Where activity is recorded.
public protocol ActivityLog: Sendable {
    func append(_ entry: ActivityEntry) async
    /// Most recent first, at most `limit` entries.
    func recent(limit: Int) async -> [ActivityEntry]
}
