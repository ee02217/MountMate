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
                    Text("\(dot(row.dot))  \(row.title)")
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                    }
                }
            }
        }

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

    private func dot(_ dot: StatusDot) -> String {
        switch dot {
        case .mounted: return "●"
        case .disabled: return "○"
        case .failed: return "▲"
        case .working: return "◌"
        }
    }
}
