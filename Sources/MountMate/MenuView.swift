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
                    // NSMenu draws a two-line title/subtitle row only when the
                    // Button's label carries two `Text` views directly — wrapping
                    // them in `Label { Text; Text } icon: { Image }` nests them one
                    // level deeper (inside Label's own composition) and NSMenu no
                    // longer finds them, collapsing the row back to one line. Keep
                    // the icon and both `Text`s as flat siblings instead.
                    // NSMenu renders item images as templates and strips any tint
                    // regardless of rendering mode, so this symbol draws monochrome
                    // here — shape is what actually carries the state in the menu;
                    // colour is a bonus only where the symbol is reused outside it.
                    let status = status(row.dot)
                    Image(systemName: status.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(status.tint)
                    Text(row.title)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
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
