import Testing
import Foundation
@testable import MountMateCore

/// A throwaway suite so no test ever reads or writes the developer's real defaults.
private func makeDefaults() -> UserDefaults {
    let suite = "com.sergio.mountmate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func unsetPreferencesHaveSensibleDefaults() async {
    let prefs = UserDefaultsPreferences(defaults: makeDefaults())

    // Matches BackstopTimerSource's own default: an unconfigured app behaves exactly
    // as it did before this milestone existed.
    #expect(await prefs.healthCheckInterval == .seconds(300))
    #expect(await prefs.notifyOnFailure == true)
    #expect(await prefs.notifyOnRecovery == true)
}

@Test func preferencesRoundTrip() async {
    let defaults = makeDefaults()
    let prefs = UserDefaultsPreferences(defaults: defaults)

    await prefs.setHealthCheckInterval(.seconds(60))
    await prefs.setNotifyOnFailure(false)

    #expect(await prefs.healthCheckInterval == .seconds(60))
    #expect(await prefs.notifyOnFailure == false)
    // Untouched settings keep their default.
    #expect(await prefs.notifyOnRecovery == true)

    // A second instance reads the same store: settings survive a relaunch.
    let reopened = UserDefaultsPreferences(defaults: defaults)
    #expect(await reopened.healthCheckInterval == .seconds(60))
}

/// A hand-edited or corrupted defaults value must not produce a zero-second sweep.
@Test func anImplausibleIntervalFallsBackToTheDefault() async {
    let defaults = makeDefaults()
    defaults.set(0, forKey: "healthCheckIntervalSeconds")
    let prefs = UserDefaultsPreferences(defaults: defaults)

    #expect(await prefs.healthCheckInterval == .seconds(300))
}
