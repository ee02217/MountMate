import Foundation

/// The text behind "Copy diagnostics".
///
/// Identifiers are included verbatim (spec §8.1): redacting the hostname is what
/// turns "failed — host unreachable" into a line that helps nobody. Passwords are
/// never in scope — they exist only in the Keychain, and nothing here reads one.
public struct DiagnosticsReport: Sendable {
    private let appVersion: String
    private let systemVersion: String
    private let accessPolicy: CredentialAccessPolicy
    private let load: EndpointLoad
    private let entries: [ActivityEntry]

    public init(
        appVersion: String,
        systemVersion: String,
        accessPolicy: CredentialAccessPolicy,
        load: EndpointLoad,
        entries: [ActivityEntry]
    ) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.accessPolicy = accessPolicy
        self.load = load
        self.entries = entries
    }

    public func text() -> String {
        var lines: [String] = []
        lines.append("MountMate \(appVersion) / macOS \(systemVersion)")

        switch accessPolicy {
        case .appRestricted:
            lines.append("Keychain access: restricted to MountMate (team-signed)")
        case .buildBound:
            lines.append(
                "Keychain access: bound to this build — macOS prompts for Keychain access after every update"
            )
        }

        lines.append("")
        lines.append("Shares:")
        if load.endpoints.isEmpty {
            lines.append("  (none configured)")
        }
        for endpoint in load.endpoints {
            let state = endpoint.enabled ? "" : "  [disabled]"
            lines.append("  \(endpoint.displayName)  \(endpoint.url.absoluteString)  \(endpoint.username)\(state)")
        }

        if !load.skipped.isEmpty {
            lines.append("")
            lines.append("Skipped entries:")
            for skipped in load.skipped {
                lines.append("  row \(skipped.index + 1): \(skipped.reason)")
            }
        }

        if let quarantined = load.quarantined {
            lines.append("")
            lines.append("Unreadable config preserved at: \(quarantined.path)")
        }

        // Repeated here because the pane has room for the whole instruction, where a
        // menu row only fits "Mount point in use". The matched string is exactly what
        // `TransitionLogger` writes for `.mountpointOccupied`; change one, change both.
        if entries.contains(where: { $0.message.contains("mount point in use") }),
           let advice = MountFailureReason.mountpointOccupied.remedy {
            lines.append("")
            lines.append("How to fix the mount point problem:")
            lines.append("  \(advice)")
        }

        lines.append("")
        lines.append("Recent activity:")
        if entries.isEmpty {
            lines.append("  (nothing recorded)")
        }
        for entry in entries {
            lines.append("  \(entry.formatted())")
        }

        return lines.joined(separator: "\n")
    }
}
