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
/// Deliberately not `UserDefaults`: a file is inspectable, diffable,
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
        let decoded: [DecodedEndpoint]
        do {
            decoded = try JSONDecoder().decode([DecodedEndpoint].self, from: data)
        } catch {
            // Not parseable as an array at all. Preserve it rather than destroy it:
            // this is a person's configuration, and the reason it is a file at all is
            // that a person can read and repair one.
            let quarantine = try quarantineFile()
            return EndpointLoad(endpoints: [], quarantined: quarantine)
        }

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

    /// Moves the unparseable file aside and returns where it went.
    ///
    /// The timestamp keeps successive failures from overwriting each other, which
    /// would defeat the point of preserving the first one.
    private func quarantineFile() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("endpoints.json.corrupt-\(stamp)")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    public func save(_ endpoints: [ShareEndpoint]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(endpoints)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `.atomic` writes a temp file and renames it into place. Without it a crash
        // or a full disk mid-write leaves a truncated file — which the next load
        // would quarantine, turning a transient failure into a lost configuration.
        try data.write(to: fileURL, options: .atomic)
    }
}
