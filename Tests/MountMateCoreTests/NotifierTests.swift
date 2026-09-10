import Testing
import Foundation
@testable import MountMateCore

private let failureNotification = PendingNotification(
    title: "Multimedia is not mounted", body: "The server could not be reached.", kind: .failure
)
private let recoveryNotification = PendingNotification(
    title: "Multimedia is mounted again", body: "The share is available.", kind: .recovery
)

@Test func bothKindsPassWhenBothAreEnabled() async {
    let recorder = RecordingNotifier()
    let gated = PreferenceGatedNotifier(
        wrapping: recorder, preferences: InMemoryPreferences()
    )

    await gated.post(failureNotification)
    await gated.post(recoveryNotification)

    #expect(await recorder.posted.count == 2)
}

@Test func disablingFailureNotificationsSuppressesOnlyThose() async {
    let recorder = RecordingNotifier()
    let gated = PreferenceGatedNotifier(
        wrapping: recorder,
        preferences: InMemoryPreferences(notifyOnFailure: false)
    )

    await gated.post(failureNotification)
    await gated.post(recoveryNotification)

    let posted = await recorder.posted
    #expect(posted.count == 1)
    #expect(posted[0].kind == .recovery)
}

@Test func disablingRecoveryNotificationsSuppressesOnlyThose() async {
    let recorder = RecordingNotifier()
    let gated = PreferenceGatedNotifier(
        wrapping: recorder,
        preferences: InMemoryPreferences(notifyOnRecovery: false)
    )

    await gated.post(failureNotification)
    await gated.post(recoveryNotification)

    let posted = await recorder.posted
    #expect(posted.count == 1)
    #expect(posted[0].kind == .failure)
}
