import Testing
import Foundation
@testable import MountMateCore

@Test func theBackstopFiresRepeatedlyAtItsInterval() async throws {
    let scheduler = FakeScheduler(limit: 3)
    let source = BackstopTimerSource(interval: .seconds(300), scheduler: scheduler)

    var received: [TriggerEvent] = []
    for await event in source.events {
        received.append(event)
        if received.count == 3 { break }
    }

    #expect(received == [.backstop, .backstop, .backstop])
    // Only the first three: the loop records a fourth sleep before `break` tears the
    // stream down, so comparing the whole array is a race.
    let first3 = Array(await scheduler.requested.prefix(3))
    #expect(first3 == [.seconds(300), .seconds(300), .seconds(300)])
}

@Test func theBackstopDefaultsToFiveMinutes() {
    #expect(BackstopTimerSource().interval == .seconds(300))
}
