import SwiftUI
import AppKit
import MountMateCore

struct DiagnosticsPane: View {
    let model: MenuModel

    @State private var entries: [ActivityEntry] = []
    @State private var load: EndpointLoad = .empty
    @State private var policy: CredentialAccessPolicy = .permissive
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if policy == .permissive {
                // Spec §6 requires this to be visible, never silent.
                Label(
                    "Passwords are readable by any process running as you. A signed installation will restrict this.",
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
                Text(entry.formatted())
                    .font(.system(.caption, design: .monospaced))
            }

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy diagnostics") { copy() }
            }
            Text("Includes your share hostnames, usernames and paths. Never includes passwords.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
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
    }
}
