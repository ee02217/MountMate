import Foundation

/// The endpoint list, as a JSON file.
///
/// Deliberately not `UserDefaults` (spec §5.5): a file is inspectable, diffable,
/// backup-able, and survives uninstall/reinstall. The cost is that a person can edit
/// it into an invalid state, which is why loading salvages rather than refuses.
public struct JSONEndpointStore: EndpointStore {
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("endpoints.json")
    }

    /// `~/Library/Application Support/com.sergio.mountmate`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("com.sergio.mountmate")
    }

    public func load() async throws -> EndpointLoad {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            // No file is a first run, not a failure.
            return .empty
        }
        let decoded = try JSONDecoder().decode([ShareEndpoint].self, from: data)
        return EndpointLoad(endpoints: decoded)
    }

    public func save(_ endpoints: [ShareEndpoint]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(endpoints)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }
}
