import Foundation

/// Turns consecutive status snapshots into log entries.
///
/// Pure and synchronous, because the rule that matters — log a change, ignore a
/// repeat — is worth testing without a clock, a filesystem or a NAS.
public enum TransitionLogger {
    public static func entries(
        from old: [EndpointStatus]?,
        to new: [EndpointStatus],
        at timestamp: Date
    ) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []

        for status in new {
            let previous = old?.first { $0.id == status.id }

            // No previous entry means either the first snapshot after launch or a
            // share just added in Settings. Both are worth a line.
            if let previous, previous.state == status.state { continue }

            entries.append(
                ActivityEntry(
                    timestamp: timestamp,
                    category: .mount,
                    share: status.displayName,
                    message: describe(status.state)
                )
            )
        }

        // Shares that disappeared are deliberately not logged here: they were
        // removed in Settings, which logs that itself, and inventing a "gone" entry
        // would report a state the engine never held.
        return entries
    }

    private static func describe(_ state: MountState) -> String {
        switch state {
        case .idle: return "idle"
        case .mounting: return "mounting"
        case .mounted(let path): return "mounted \(path)"
        case .stale(let path): return "not responding at \(path)"
        case .failed(let failure): return "failed — \(describe(failure.reason))"
        }
    }

    private static func describe(_ reason: MountFailureReason) -> String {
        switch reason {
        case .authenticationFailed: return "authentication failed"
        case .hostUnreachable: return "host unreachable"
        case .shareNotFound: return "share not found"
        case .mountpointBusy: return "mount point busy"
        case .mountpointOccupied: return "mount point in use"
        case .timedOut: return "timed out"
        case .serverNotResponding: return "server not responding"
        case .noCredential: return "no password saved"
        case .unknown: return "unknown error"
        }
    }
}
