import Foundation

public enum StatusDot: Sendable, Equatable {
    case mounted
    case disabled
    case failed
    case working
}

/// One menu row, already resolved to what should be drawn.
public struct MenuRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let subtitle: String?
    public let dot: StatusDot
    public let actionTitle: String
}

/// The menu, derived from a status snapshot.
///
/// Pure by design (spec §8): this holds the only UI logic worth testing, so it is a
/// value with no SwiftUI in it. The views over it are thin enough to check by
/// reading them.
public struct MenuPresentation: Sendable, Equatable {
    public let iconSymbolName: String
    public let rows: [MenuRow]

    public init(statuses: [EndpointStatus]) {
        self.rows = statuses.map(Self.row(for:))
        self.iconSymbolName = Self.icon(for: statuses)
    }

    private static func icon(for statuses: [EndpointStatus]) -> String {
        // A disabled endpoint is a choice, not a fault: it must never raise the
        // warning badge, or the icon cries wolf for as long as it stays disabled.
        let active = statuses.filter(\.enabled)

        if active.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
            return "externaldrive.badge.exclamationmark"
        }
        if active.isEmpty {
            return "externaldrive"
        }
        if active.allSatisfy({ if case .mounted = $0.state { return true } else { return false } }) {
            return "externaldrive.badge.checkmark"
        }
        return "externaldrive"
    }

    private static func row(for status: EndpointStatus) -> MenuRow {
        guard status.enabled else {
            return MenuRow(
                id: status.id,
                title: status.displayName,
                subtitle: "Disabled",
                dot: .disabled,
                actionTitle: "Mount"
            )
        }

        switch status.state {
        case .mounted(let path):
            return MenuRow(
                id: status.id, title: status.displayName, subtitle: path,
                dot: .mounted, actionTitle: "Unmount"
            )
        case .stale(let path):
            return MenuRow(
                id: status.id, title: status.displayName, subtitle: "\(path) (not responding)",
                dot: .working, actionTitle: "Unmount"
            )
        case .mounting:
            return MenuRow(
                id: status.id, title: status.displayName, subtitle: "Mounting…",
                dot: .working, actionTitle: "Mount"
            )
        case .idle:
            return MenuRow(
                id: status.id, title: status.displayName, subtitle: nil,
                dot: .working, actionTitle: "Mount"
            )
        case .failed(let failure):
            return MenuRow(
                id: status.id, title: status.displayName,
                subtitle: Self.describe(failure.reason),
                dot: .failed, actionTitle: "Retry"
            )
        }
    }

    /// Plain language, because this is read by a person deciding what to do next.
    private static func describe(_ reason: MountFailureReason) -> String {
        switch reason {
        case .authenticationFailed: return "Authentication failed"
        case .hostUnreachable: return "Host unreachable"
        case .shareNotFound: return "Share not found"
        case .mountpointBusy: return "Mount point busy"
        case .timedOut: return "Timed out"
        case .noCredential: return "No password saved"
        case .unknown: return "Failed"
        }
    }
}
