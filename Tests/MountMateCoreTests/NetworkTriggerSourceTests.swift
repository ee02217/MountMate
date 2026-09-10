import Testing
import Foundation
@testable import MountMateCore

@Test func theFirstSatisfiedPathIsAReconnect() {
    var filter = PathTransitionFilter()
    #expect(filter.event(forSatisfied: true) == .networkBecameSatisfied)
}

@Test func regainingThePathIsAReconnect() {
    var filter = PathTransitionFilter()
    _ = filter.event(forSatisfied: true)
    #expect(filter.event(forSatisfied: false) == nil)
    #expect(filter.event(forSatisfied: true) == .networkBecameSatisfied)
}

@Test func aRepeatedSatisfiedUpdateIsAnOrdinaryChange() {
    var filter = PathTransitionFilter()
    _ = filter.event(forSatisfied: true)
    #expect(filter.event(forSatisfied: true) == .networkChanged)
    #expect(filter.event(forSatisfied: true) == .networkChanged)
}

@Test func losingThePathEmitsNothing() {
    var filter = PathTransitionFilter()
    _ = filter.event(forSatisfied: true)
    #expect(filter.event(forSatisfied: false) == nil)
    #expect(filter.event(forSatisfied: false) == nil)
}

/// The reason the filter exists: a flapping link must not reset backoff on every
/// callback. Only the genuine recoveries may carry a resetting event.
@Test func aFlappingLinkResetsBackoffOnlyOnRealRecoveries() {
    var filter = PathTransitionFilter()
    let flapping = [true, true, false, true, true, true, false, false, true]

    let resets = flapping
        .compactMap { filter.event(forSatisfied: $0) }
        .filter(\.resetsBackoff)
        .count

    #expect(resets == 3)
}

@Test func aWakeNotificationBecomesAWakeEvent() async throws {
    let center = NotificationCenter()
    let name = Notification.Name("TestWake")
    let source = WakeTriggerSource(center: center, name: name)

    let events = source.events
    let collector = Task { () -> TriggerEvent? in
        for await event in events { return event }
        return nil
    }

    // Give the observer a moment to register before posting.
    try await Task.sleep(for: .milliseconds(20))
    center.post(name: name, object: nil)

    #expect(await collector.value == .wake)
}
