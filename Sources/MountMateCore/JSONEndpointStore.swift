import Foundation

/// One array element, decoded without throwing.
///
/// This wrapper exists for one reason: a throwing `decode` inside an unkeyed
/// container does not advance the container's index, so the obvious
/// `while !isAtEnd { try? decode() }` loop never terminates. Capturing the error
/// inside `init(from:)` guarantees the element is always consumed.
private struct DecodedEndpoint: Decodable {
    let result: Result<ShareEndpoint, any Error>

    init(from decoder: any Decoder) throws {
        do {
            result = .success(try ShareEndpoint(from: decoder))
        } catch {
            result = .failure(error)
        }
    }
}

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
        let decoded = try JSONDecoder().decode([DecodedEndpoint].self, from: data)

        var endpoints: [ShareEndpoint] = []
        var skipped: [SkippedEndpoint] = []
        for (index, element) in decoded.enumerated() {
            switch element.result {
            case .success(let endpoint):
                endpoints.append(endpoint)
            case .failure(let error):
                // `ShareEndpointError` has a `description` worth showing a person;
                // a decoding error's does not, but it is still better than nothing.
                let reason = (error as? ShareEndpointError)?.description
                    ?? String(describing: error)
                skipped.append(SkippedEndpoint(index: index, reason: reason))
            }
        }
        return EndpointLoad(endpoints: endpoints, skipped: skipped)
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
