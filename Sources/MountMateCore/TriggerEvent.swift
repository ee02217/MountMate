import Foundation

/// Something that justifies asking the engine to check its endpoints.
public enum TriggerEvent: Sendable, Equatable {
    /// The app started.
    case launch
    /// The machine woke from sleep.
    case wake
    /// The network path went unsatisfied -> satisfied. A genuine reconnect.
    case networkBecameSatisfied
    /// Any other path update: satisfied -> satisfied, or an interface change.
    case networkChanged
    /// The user asked, from the menu or Settings. `nil` means every endpoint.
    case userRequested(UUID?)
    /// The slow timer fired.
    case backstop
}

extension TriggerEvent {
    /// Whether this event invalidates prior failure history.
    ///
    /// Only a genuine reconnect or a wake justifies clearing the ladder.
    /// `NWPathMonitor` fires repeatedly while a flaky link settles, so resetting on
    /// every path update would hot-loop mount attempts — precisely what the backoff
    /// exists to prevent. `.launch` is false because at launch there is no history to
    /// clear, and `.userRequested` is false because `ensureMounted` already attempts
    /// immediately, so the user gets their attempt without discarding the ladder.
    public var resetsBackoff: Bool {
        switch self {
        case .wake, .networkBecameSatisfied:
            return true
        case .launch, .networkChanged, .userRequested, .backstop:
            return false
        }
    }
}
