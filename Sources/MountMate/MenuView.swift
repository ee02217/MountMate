import SwiftUI
import AppKit
import MountMateCore

struct MenuView: View {
    let model: MenuModel

    var body: some View {
        if model.presentation.rows.isEmpty {
            Text("No shares configured")
            Text("Edit endpoints.json to add one")
                .font(.caption)
        } else {
            ForEach(model.presentation.rows) { row in
                Button {
                    // ⌥-click reveals instead of acting (spec §8).
                    if NSEvent.modifierFlags.contains(.option),
                       let path = subtitlePath(for: row) {
                        model.reveal(path)
                    } else {
                        model.toggle(row.id)
                    }
                } label: {
                    Label {
                        Text(row.title)
                        if let subtitle = row.subtitle {
                            Text(subtitle)
                        }
                    } icon: {
                        let status = status(row.dot)
                        Image(systemName: status.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(status.tint)
                    }
                }
            }
        }

        Color.clear.frame(minWidth: 220, maxHeight: 0)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit MountMate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Only a row that is actually attached has somewhere to reveal.
    private func subtitlePath(for row: MenuRow) -> String? {
        guard row.dot == .mounted else { return nil }
        return row.subtitle
    }

    /// Colour first, shape second — the order every macOS status indicator uses, so
    /// it survives a glance nobody consciously takes. Shape still distinguishes all
    /// four states, so the tint is reinforcement rather than the only channel.
    private func status(_ dot: StatusDot) -> (symbol: String, tint: Color) {
        switch dot {
        case .mounted: return ("checkmark.circle.fill", .green)
        case .failed: return ("exclamationmark.circle.fill", .red)
        case .disabled: return ("circle", .secondary)
        case .working: return ("arrow.triangle.2.circlepath", .secondary)
        }
    }
}
