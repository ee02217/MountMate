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
