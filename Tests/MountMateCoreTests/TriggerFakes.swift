import Foundation
@testable import MountMateCore

/// A source the test drives by hand.
///
/// The stream is created once in `init` and handed out unchanged, so `yield` before
/// iteration still lands: `AsyncStream` buffers until consumed.
final class FakeTriggerSource: TriggerSource, @unchecked Sendable {
    let events: AsyncStream<TriggerEvent>
    private let continuation: AsyncStream<TriggerEvent>.Continuation

    init() {
        var captured: AsyncStream<TriggerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func yield(_ event: TriggerEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
}

/// A scheduler that never actually waits.
///
/// Records every requested duration, then returns at once so the retry it guards runs
/// immediately. After `limit` sleeps it parks forever instead: without that bound a
/// permanently-failing endpoint would spin the retry ladder as fast as the CPU allows.
/// A mount table that also counts liveness probes, so a test can tell a re-probe
/// apart from a remount. A separate type rather than a counter on
/// `FakeMountInspector`, so the tests that use that fake stay unchanged.
actor CountingMountInspector: MountInspector {
    private var volumes: [MountedVolume] = []
    private var responsive: Set<String> = []
    private(set) var responsiveChecks = 0

    func setVolumes(_ volumes: [MountedVolume]) { self.volumes = volumes }
    func setResponsive(_ paths: Set<String>) { self.responsive = paths }

    func mountedVolumes() async -> [MountedVolume] { volumes }

    func isResponsive(path: String) async -> Bool {
        responsiveChecks += 1
        return responsive.contains(path)
    }

    /// These tests are about trigger cadence, not mountpoints: nothing is ever in the
    /// way, so every attempt reaches the mount it is counting.
    func directoryState(at path: String) async -> DirectoryState { .absent }
}

actor FakeScheduler: Scheduler {
    private(set) var requested: [Duration] = []
    private let limit: Int

    init(limit: Int = 1) { self.limit = limit }

    func sleep(for duration: Duration) async throws {
        requested.append(duration)
        guard requested.count <= limit else {
            // Park until the enclosing task is cancelled by `stop()` or test teardown.
            try await Task.sleep(for: .seconds(3600))
            return
        }
    }
}
