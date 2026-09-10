import Testing
import Foundation
@testable import MountMateCore

@Test func firstAttemptUsesInitialDelay() {
    let policy = BackoffPolicy(initialSeconds: 5, maximumSeconds: 300, multiplier: 2)
    #expect(policy.delay(forAttempt: 1) == .seconds(5))
}

@Test func delayGrowsGeometrically() {
    let policy = BackoffPolicy(initialSeconds: 5, maximumSeconds: 300, multiplier: 2)
    #expect(policy.delay(forAttempt: 2) == .seconds(10))
    #expect(policy.delay(forAttempt: 3) == .seconds(20))
    #expect(policy.delay(forAttempt: 4) == .seconds(40))
}

@Test func delayIsCappedAtMaximum() {
    let policy = BackoffPolicy(initialSeconds: 5, maximumSeconds: 300, multiplier: 2)
    #expect(policy.delay(forAttempt: 50) == .seconds(300))
}

@Test func attemptZeroOrNegativeYieldsInitialDelay() {
    let policy = BackoffPolicy(initialSeconds: 5, maximumSeconds: 300, multiplier: 2)
    #expect(policy.delay(forAttempt: 0) == .seconds(5))
    #expect(policy.delay(forAttempt: -3) == .seconds(5))
}

@Test func standardPolicyMatchesSpec() {
    // Spec section 9: 5s -> 5 min cap.
    #expect(BackoffPolicy.standard.delay(forAttempt: 1) == .seconds(5))
    #expect(BackoffPolicy.standard.delay(forAttempt: 99) == .seconds(300))
}
