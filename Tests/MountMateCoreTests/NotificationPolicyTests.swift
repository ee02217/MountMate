import Testing
import Foundation
@testable import MountMateCore

private func failing(_ id: UUID, _ name: String = "Multimedia") -> EndpointStatus {
    EndpointStatus(
        id: id, displayName: name,
        state: .failed(MountFailure(reason: .hostUnreachable)), enabled: true
    )
}

private func mounted(_ id: UUID, _ name: String = "Multimedia") -> EndpointStatus {
    EndpointStatus(
        id: id, displayName: name,
        state: .mounted(path: "/Volumes/\(name)"), enabled: true
    )
}

@Test func oneFailureIsNotWorthInterrupting() {
    var policy = NotificationPolicy()
    let id = UUID()

    // The backoff ladder retries in five seconds. A Wi-Fi hiccup that heals on the
    // first retry must never reach the notification centre.
    #expect(policy.evaluate([failing(id)]).isEmpty)
}

@Test func theSecondConsecutiveFailureIsAnnounced() {
    var policy = NotificationPolicy()
    let id = UUID()

    _ = policy.evaluate([failing(id)])
    let notifications = policy.evaluate([failing(id)])

    #expect(notifications.count == 1)
    #expect(notifications[0].kind == .failure)
    #expect(notifications[0].title.contains("Multimedia"))
    #expect(notifications[0].body.contains("could not be reached"))
}

@Test func furtherFailuresSayNothingMore() {
    var policy = NotificationPolicy()
    let id = UUID()

    _ = policy.evaluate([failing(id)])
    _ = policy.evaluate([failing(id)])
    // Already told; repeating it every sweep is what makes people turn
    // notifications off.
    #expect(policy.evaluate([failing(id)]).isEmpty)
    #expect(policy.evaluate([failing(id)]).isEmpty)
}

@Test func recoveryIsAnnouncedOnlyIfTheFailureWas() {
    var policy = NotificationPolicy()
    let id = UUID()

    _ = policy.evaluate([failing(id)])
    _ = policy.evaluate([failing(id)])
    let recovery = policy.evaluate([mounted(id)])

    #expect(recovery.count == 1)
    #expect(recovery[0].kind == .recovery)
}

@Test func aBlipThatHealsBeforeBeingAnnouncedStaysSilent() {
    var policy = NotificationPolicy()
    let id = UUID()

    _ = policy.evaluate([failing(id)])
    // Recovered on the first retry: nothing was announced, so nothing is retracted.
    #expect(policy.evaluate([mounted(id)]).isEmpty)
}

@Test func aSecondOutageIsAnnouncedAgain() {
    var policy = NotificationPolicy()
    let id = UUID()

    _ = policy.evaluate([failing(id)])
    _ = policy.evaluate([failing(id)])
    _ = policy.evaluate([mounted(id)])

    _ = policy.evaluate([failing(id)])
    let second = policy.evaluate([failing(id)])

    // The state resets on recovery: a new outage tomorrow is news again.
    #expect(second.count == 1)
    #expect(second[0].kind == .failure)
}
