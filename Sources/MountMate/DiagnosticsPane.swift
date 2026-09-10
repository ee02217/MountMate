import SwiftUI
import AppKit
import MountMateCore

struct DiagnosticsPane: View {
    let model: MenuModel

    @State private var entries: [ActivityEntry] = []
    @State private var load: EndpointLoad = .empty
    @State private var policy: CredentialAccessPolicy = .permissive
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if policy == .permissive {
                // Spec §6 requires this to be visible, never silent — and §6.1
                // requires it not to promise a fix that does not exist.
                Label(
                    "Passwords are readable by any process running as you — the same as a file in your home folder. macOS cannot restrict this further without a paid Apple developer account.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
            }

            if !load.skipped.isEmpty {
                Text("Skipped entries in endpoints.json").font(.headline)
                ForEach(load.skipped, id: \.index) { skipped in
                    Text("Row \(skipped.index + 1): \(skipped.reason)").font(.caption)
                }
            }

            if let quarantined = load.quarantined {
                Text("Unreadable config preserved at \(quarantined.path)")
                    .font(.caption)
            }

            Text("Recent activity").font(.headline)
            List(Array(entries.enumerated()), id: \.offset) { _, entry in
                ActivityRow(entry: entry)
                    .listRowSeparator(.hidden)
            }
            .contentMargins(.bottom, 76, for: .scrollContent)

        }
        .padding()
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Includes your share hostnames, usernames and paths. Never includes passwords.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy diagnostics") { copy() }
                        .buttonStyle(.glass)
                }
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await model.activityLog.recent(limit: 200)
        load = await model.controllerLoad()
        policy = await model.controllerPolicy()
    }

    private func copy() {
        let report = DiagnosticsReport(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessPolicy: policy,
            load: load,
            entries: entries
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text(), forType: .string)
        copied = true

        // A control's label says what it does. Left alone, this one read "Copied"
        // indefinitely — observed still saying it ten minutes after the click, which
        // describes a past event rather than the action available now.
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// One activity row, resolved to what should be drawn.
///
/// The symbol is chosen from the entry's category and, for mount entries, from the
/// message. Reading the message is stringly-typed and therefore fragile — if it ever
/// disagrees with reality, the honest fix is a state field on `ActivityEntry` rather
/// than more string matching here.
struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var message: String {
        if let share = entry.share { return "\(share): \(entry.message)" }
        return entry.message
    }

    private var symbol: String {
        switch entry.category {
        case .lifecycle: return "power"
        case .user: return "hand.tap"
        case .mount:
            if entry.message.hasPrefix("failed") { return "exclamationmark.circle.fill" }
            if entry.message.hasPrefix("mounted") { return "checkmark.circle.fill" }
            return "circle"
        }
    }

    private var tint: Color {
        switch entry.category {
        case .lifecycle, .user: return .secondary
        case .mount:
            if entry.message.hasPrefix("failed") { return .red }
            if entry.message.hasPrefix("mounted") { return .green }
            return .secondary
        }
    }
}
