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

@Test func theBackstopDefaultsToFiveMinutes() async throws {
    let scheduler = FakeScheduler(limit: 1)
    let source = BackstopTimerSource(scheduler: scheduler)

    for await _ in source.events { break }

    // Asserts the behaviour — what it actually sleeps for — rather than a stored
    // property that happens to hold the same number.
    #expect(await scheduler.requested.first == .seconds(300))
}

/// Hands out a scripted sequence of intervals, one per call.
///
/// Mutating a preference from the consuming loop instead would race: with an
/// immediate scheduler the producer reads the next interval before the consumer has
/// processed the previous event, so the change lands too late to observe.
private actor ScriptedInterval {
    private var values: [Duration]

    init(_ values: [Duration]) { self.values = values }

    func next() -> Duration {
        values.isEmpty ? .seconds(300) : values.removeFirst()
    }
}

@Test func theBackstopReadsTheIntervalBeforeEachSleep() async throws {
    let scheduler = FakeScheduler(limit: 3)
    let script = ScriptedInterval([.seconds(300), .seconds(60), .seconds(60)])
    let source = BackstopTimerSource(
        interval: { await script.next() },
        scheduler: scheduler
    )

    var seen = 0
    for await _ in source.events {
        seen += 1
        if seen == 3 { break }
    }

    // Re-read each cycle rather than captured once: a preference change lands on the
    // next sleep, with no restart of the coordinator.
    let requested = await scheduler.requested
    #expect(Array(requested.prefix(2)) == [.seconds(300), .seconds(60)])
}
