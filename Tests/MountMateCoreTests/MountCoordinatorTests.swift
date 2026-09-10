import Testing
import Foundation
@testable import MountMateCore

@Test func onlyGenuineTransitionsResetBackoff() {
    #expect(TriggerEvent.wake.resetsBackoff)
    #expect(TriggerEvent.networkBecameSatisfied.resetsBackoff)

    #expect(!TriggerEvent.networkChanged.resetsBackoff)
    #expect(!TriggerEvent.launch.resetsBackoff)
    #expect(!TriggerEvent.backstop.resetsBackoff)
    #expect(!TriggerEvent.userRequested(nil).resetsBackoff)
}

@Test func fakeSourceDeliversYieldedEvents() async {
    let source = FakeTriggerSource()
    source.yield(.wake)
    source.yield(.backstop)
    source.finish()

    var received: [TriggerEvent] = []
    for await event in source.events { received.append(event) }

    #expect(received == [.wake, .backstop])
}
