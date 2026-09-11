import Foundation

public struct PendingNotification: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case failure
        case recovery
    }

    public let title: String
    public let body: String
    public let kind: Kind

    public init(title: String, body: String, kind: Kind) {
        self.title = title
        self.body = body
        self.kind = kind
    }
}

/// Decides what is worth interrupting someone about.
///
/// The first failure is not announced, because the backoff ladder retries
/// within seconds and a Wi-Fi hiccup is not news. The second consecutive failure is.
/// Further failures are not — you have been told. Recovery is announced only if the
/// failure was, so a blip that heals before anyone was told stays entirely silent.
///
/// Pure per-endpoint state, so all of that is testable with no clock and no
/// notification centre.
public struct NotificationPolicy: Sendable {
    private struct EndpointState {
        var consecutiveFailures = 0
        var announced = false
    }

    /// Failures before an announcement. Two means "it survived one retry".
    private static let threshold = 2

    private var states: [UUID: EndpointState] = [:]

    public init() {}

    public mutating func evaluate(
        _ snapshot: [EndpointStatus]
    ) -> [PendingNotification] {
        var notifications: [PendingNotification] = []
        var seen: Set<UUID> = []

        for status in snapshot {
            seen.insert(status.id)
            var state = states[status.id] ?? EndpointState()

            switch status.state {
            case .failed(let failure):
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= Self.threshold, !state.announced {
                    state.announced = true
                    notifications.append(
                        PendingNotification(
                            title: "\(status.displayName) is not mounted",
                            body: Self.describe(failure.reason),
                            kind: .failure
                        )
                    )
                }

            case .mounted:
                if state.announced {
                    notifications.append(
                        PendingNotification(
                            title: "\(status.displayName) is mounted again",
                            body: "The share is available.",
                            kind: .recovery
                        )
                    )
                }
                state = EndpointState()

            case .idle, .mounting, .stale:
                // Transient or deliberate: neither an outage nor a recovery. Leave
                // the counters alone rather than resetting a real outage because one
                // sweep caught it mid-attempt.
                break
            }

            states[status.id] = state
        }

        // Forget shares that no longer exist, so a removed-and-re-added share does
        // not inherit an outage it was not part of.
        states = states.filter { seen.contains($0.key) }
        return notifications
    }

    private static func describe(_ reason: MountFailureReason) -> String {
        switch reason {
        case .authenticationFailed: return "Authentication failed."
        case .hostUnreachable: return "The server could not be reached."
        case .shareNotFound: return "The share was not found."
        case .mountpointBusy: return "The mount point is busy."
        case .mountpointOccupied: return "Another item is using that folder in /Volumes."
        case .timedOut: return "The mount timed out."
        case .serverNotResponding:
            return "Earlier mount attempts are still waiting, so MountMate is holding off."
        case .noCredential: return "No password is saved for this share."
        case .unknown: return "The mount failed."
        }
    }
}
