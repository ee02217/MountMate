import Foundation

/// Settings that are not endpoints.
///
/// `UserDefaults` rather than a file (spec §8.2): §5.5's reasons for choosing a file
/// were about a list a person hand-edits, diffs and restores, none of which describes
/// an interval and two toggles.
public protocol PreferencesStore: Sendable {
    var healthCheckInterval: Duration { get async }
    var notifyOnFailure: Bool { get async }
    var notifyOnRecovery: Bool { get async }

    func setHealthCheckInterval(_ interval: Duration) async
    func setNotifyOnFailure(_ enabled: Bool) async
    func setNotifyOnRecovery(_ enabled: Bool) async
}

/// A struct rather than an actor, marked `@unchecked Sendable`.
///
/// `UserDefaults` is documented thread-safe but is not `Sendable`, so handing one to
/// an actor's initializer is rejected as a potential data race. Wrapping it in an
/// actor would also add suspension points to what are plain synchronous reads of an
/// already-synchronised store. The unchecked conformance is the accurate claim: the
/// only stored property is a thread-safe reference type.
public struct UserDefaultsPreferences: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults

    /// The interval an unconfigured app uses — the same value `BackstopTimerSource`
    /// defaulted to before this milestone, so behaviour is unchanged until someone
    /// changes it.
    public static let defaultInterval: Duration = .seconds(300)
    /// Below this, sweeps would overlap and hammer a NAS that is already struggling.
    private static let minimumIntervalSeconds = 30

    private enum Key {
        static let interval = "healthCheckIntervalSeconds"
        static let notifyFailure = "notifyOnFailure"
        static let notifyRecovery = "notifyOnRecovery"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var healthCheckInterval: Duration {
        let seconds = defaults.integer(forKey: Key.interval)
        // `integer(forKey:)` returns 0 for both "unset" and "set to nonsense", and
        // either way a zero-second sweep would spin. Both fall back.
        guard seconds >= Self.minimumIntervalSeconds else { return Self.defaultInterval }
        return .seconds(seconds)
    }

    /// Absent means on. Notifications are the reason someone enabled this app's
    /// supervision in the first place, so silence should be a choice, not a default.
    public var notifyOnFailure: Bool {
        defaults.object(forKey: Key.notifyFailure) as? Bool ?? true
    }

    public var notifyOnRecovery: Bool {
        defaults.object(forKey: Key.notifyRecovery) as? Bool ?? true
    }

    public func setHealthCheckInterval(_ interval: Duration) {
        defaults.set(Int(interval.components.seconds), forKey: Key.interval)
    }

    public func setNotifyOnFailure(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.notifyFailure)
    }

    public func setNotifyOnRecovery(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.notifyRecovery)
    }
}
