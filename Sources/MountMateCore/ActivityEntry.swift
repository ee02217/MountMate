import Foundation

public enum ActivityCategory: String, Sendable, Equatable {
    /// The app started or stopped.
    case lifecycle
    /// A share changed state.
    case mount
    /// Someone clicked something.
    case user
}

/// One line in the activity log.
public struct ActivityEntry: Sendable, Equatable {
    public let timestamp: Date
    public let category: ActivityCategory
    /// The share this concerns, if it concerns one.
    public let share: String?
    public let message: String

    public init(
        timestamp: Date = Date(),
        category: ActivityCategory,
        share: String?,
        message: String
    ) {
        self.timestamp = timestamp
        self.category = category
        self.share = share
        self.message = message
    }

    /// Time first, because a log is read by scanning down the left edge for *when*.
    public func formatted() -> String {
        let stamp = Self.formatter.string(from: timestamp)
        if let share {
            return "\(stamp)  \(share): \(message)"
        }
        return "\(stamp)  \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
