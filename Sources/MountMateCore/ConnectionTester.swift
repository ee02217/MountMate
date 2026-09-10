import Foundation

public enum ConnectionTestResult: Sendable, Equatable {
    /// The test mounted it, reported, and detached again.
    case succeeded(path: String)
    /// It was already mounted before the test, and was left that way.
    case alreadyMounted(path: String)
    case failed(MountFailure)
}

/// Answers "would this actually mount?" and puts things back.
///
/// NetFS has no dry run, so a successful test really does attach a volume (spec §8).
/// Whether that volume should survive the test depends entirely on whether the test
/// created it — detaching a share that was already working could pull it out from
/// under something mid-read.
public struct ConnectionTester: Sendable {
    private let service: any MountService
    private let inspector: any MountInspector
    private let deadline: Duration

    public init(
        service: any MountService,
        inspector: any MountInspector,
        deadline: Duration = .seconds(45)
    ) {
        self.service = service
        self.inspector = inspector
        self.deadline = deadline
    }

    public func test(
        _ endpoint: ShareEndpoint,
        password: String?
    ) async -> ConnectionTestResult {
        let identifier = endpoint.mountFromIdentifier
        if let existing = await inspector.mountedVolumes().first(where: { $0.from == identifier }) {
            return .alreadyMounted(path: existing.on)
        }

        guard let password, !password.isEmpty else {
            // Reported rather than attempted: a mount with no password would either
            // fail confusingly or prompt, and prompting is the bug this app exists
            // to remove.
            return .failed(MountFailure(reason: .noCredential))
        }

        let service = self.service
        do {
            let path = try await withTimeout(deadline) {
                try await service.mount(endpoint: endpoint, password: password)
            }
            // Clean up only what this test attached.
            try? await service.unmount(path: path, force: false)
            return .succeeded(path: path)
        } catch let failure as MountFailure {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(MountFailure(reason: .timedOut))
        } catch {
            return .failed(MountFailure(reason: .unknown))
        }
    }
}
