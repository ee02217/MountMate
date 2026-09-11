import Foundation

/// One entry that could not be turned into a `ShareEndpoint`.
///
/// `index` is the entry's position in the file, so a person can find it: the entry
/// may have no usable name, or no name at all, but it always has a position.
public struct SkippedEndpoint: Sendable, Equatable {
    public let index: Int
    public let reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

/// What a load recovered.
///
/// Loading is salvaging, not all-or-nothing: one hand-edited entry with a
/// typo must not stop the other shares mounting.
public struct EndpointLoad: Sendable {
    public let endpoints: [ShareEndpoint]
    public let skipped: [SkippedEndpoint]
    /// Where an unparseable file was preserved, if there was one. The original is
    /// never overwritten — a person's config is not this app's to destroy.
    public let quarantined: URL?

    public init(
        endpoints: [ShareEndpoint],
        skipped: [SkippedEndpoint] = [],
        quarantined: URL? = nil
    ) {
        self.endpoints = endpoints
        self.skipped = skipped
        self.quarantined = quarantined
    }

    /// A first run: no file, nothing skipped, nothing wrong.
    public static let empty = EndpointLoad(endpoints: [])
}

/// Where the endpoint list lives.
public protocol EndpointStore: Sendable {
    func load() async throws -> EndpointLoad
    func save(_ endpoints: [ShareEndpoint]) async throws
}
