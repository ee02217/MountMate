import Foundation
@testable import MountMateCore

/// An endpoint store with no filesystem behind it.
actor InMemoryEndpointStore: EndpointStore {
    private var endpoints: [ShareEndpoint]

    init(endpoints: [ShareEndpoint] = []) { self.endpoints = endpoints }

    func load() async throws -> EndpointLoad { EndpointLoad(endpoints: endpoints) }
    func save(_ endpoints: [ShareEndpoint]) async throws { self.endpoints = endpoints }
}
