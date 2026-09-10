import Foundation

/// Decides *when* the engine runs.
///
/// The engine deliberately never sleeps or schedules — it computes `retryDelay(for:)`
/// and stops. This actor is the other half: it listens to trigger sources, sweeps
/// endpoints through `ensureMounted`, and owns every timer in the system.
public actor MountCoordinator {
    private let engine: MountEngine
    private let endpointsProvider: @Sendable () async -> [ShareEndpoint]
    private let sources: [any TriggerSource]

    public init(
        engine: MountEngine,
        endpointsProvider: @escaping @Sendable () async -> [ShareEndpoint],
        sources: [any TriggerSource]
    ) {
        self.engine = engine
        self.endpointsProvider = endpointsProvider
        self.sources = sources
    }

    /// Acts on one trigger.
    ///
    /// Public rather than private so tests drive the coordinator directly instead of
    /// through a stream, which keeps them free of any timing assumption.
    public func handle(_ event: TriggerEvent) async {
        // Before the sweep, so this event's own attempt starts from a clean ladder.
        if event.resetsBackoff {
            await engine.resetBackoff()
        }

        switch event {
        case .userRequested(.some(let id)):
            guard let endpoint = await endpointsProvider().first(where: { $0.id == id })
            else { return }
            await visit(endpoint)
        default:
            for endpoint in await endpointsProvider() {
                await visit(endpoint)
            }
        }
    }

    /// One pass over a single endpoint.
    private func visit(_ endpoint: ShareEndpoint) async {
        await engine.ensureMounted(endpoint)
    }
}
