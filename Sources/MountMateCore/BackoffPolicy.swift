import Foundation

/// Exponential retry delay, capped. Pure and synchronous so it is trivially testable;
/// the engine stores an attempt count and asks this for the next delay.
public struct BackoffPolicy: Sendable, Equatable {
    public let initialSeconds: Double
    public let maximumSeconds: Double
    public let multiplier: Double

    public init(initialSeconds: Double, maximumSeconds: Double, multiplier: Double) {
        self.initialSeconds = initialSeconds
        self.maximumSeconds = maximumSeconds
        self.multiplier = multiplier
    }

    /// Spec section 9: 5s initial, 5 minute cap.
    public static let standard = BackoffPolicy(
        initialSeconds: 5, maximumSeconds: 300, multiplier: 2
    )

    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .seconds(initialSeconds) }
        let raw = initialSeconds * pow(multiplier, Double(attempt - 1))
        return .seconds(min(raw, maximumSeconds))
    }
}
