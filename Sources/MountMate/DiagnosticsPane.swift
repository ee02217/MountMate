import SwiftUI
import AppKit
import MountMateCore

/// Clearance the floating glass bar needs from the list scrolling beneath it.
///
/// Derived from the bar's construction: its `.padding()` adds ~16pt above and below,
/// the button is roughly 20-24pt tall, and the inset adds `.padding(.bottom, 8)` under
/// the capsule — 60-70pt in all. 76 clears that with a little margin.
enum GlassBar {
    static let clearance: CGFloat = 76
}

struct DiagnosticsPane: View {
    let model: MenuModel

    @State private var entries: [ActivityEntry] = []
    @State private var load: EndpointLoad = .empty
    @State private var policy: CredentialAccessPolicy?
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if policy == .buildBound {
                // Spec §6: the weaker case must be visible, never silent — and it has
                // to say what the user can do about it.
                Label {
                    Text("This copy of MountMate isn't signed with a developer team, so macOS asks for your login password after every update — and until someone answers, shares can't mount. Installing it with an Apple Development identity stops the prompts.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(12)
                // Held to a readable measure; at full width it runs past 100
                // characters a line.
                .frame(maxWidth: 520, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
            // Lets the last rows scroll clear of the floating bar.
            .contentMargins(.bottom, GlassBar.clearance, for: .scrollContent)

        }
        .padding()
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Includes your share hostnames, usernames and paths. Never includes passwords.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") { copy() }
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
            accessPolicy: policy ?? .buildBound,
            load: load,
            entries: entries
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text(), forType: .string)
        copied = true

        // A button's title says what it will do, so "Copied" reverts after a moment
        // rather than describing a past event indefinitely.
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
            // Exact wording comes from TransitionLogger.describe and
            // MountEngine's stray-detach log: idle, mounting, "mounted <path>",
            // "not responding at <path>", "failed — <reason>", and
            // "could not detach stray mount at <path>".
            if entry.message.hasPrefix("failed") { return "exclamationmark.circle.fill" }
            if entry.message.hasPrefix("mounted") { return "checkmark.circle.fill" }
            if entry.message.hasPrefix("not responding") { return "exclamationmark.triangle.fill" }
            if entry.message.hasPrefix("could not detach") { return "exclamationmark.triangle.fill" }
            if entry.message.hasPrefix("mounting") { return "arrow.triangle.2.circlepath" }
            if entry.message.hasPrefix("idle") { return "circle" }
            return "circle"
        }
    }

    private var tint: Color {
        switch entry.category {
        case .lifecycle, .user: return .secondary
        case .mount:
            if entry.message.hasPrefix("failed") { return .red }
            if entry.message.hasPrefix("mounted") { return .green }
            if entry.message.hasPrefix("not responding") { return .orange }
            if entry.message.hasPrefix("could not detach") { return .orange }
            return .secondary
        }
    }
}
