import Foundation

/// Runs `operation`, abandoning it if it exceeds `duration`.
///
/// This exists as insurance, not as the primary defence. With `kNAUIOptionNoUI` there
/// should be no dialog to block on — but the shell implementation this replaces lost
/// 7h40m to a blocking mount call, so every attempt gets a deadline anyway.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw MountFailure(reason: .timedOut)
        }
        guard let result = try await group.next() else {
            throw MountFailure(reason: .timedOut)
        }
        group.cancelAll()
        return result
    }
}
