import SwiftUI
import ServiceManagement
import MountMateCore

struct SettingsView: View {
    let model: MenuModel

    var body: some View {
        TabView {
            SharesPane(model: model)
                .tabItem { Label("Shares", systemImage: "externaldrive") }
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsPane(model: model)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        // A floor, not a fixed size. The old 520x380 fought macOS 26's window
        // sizing; removing it entirely let the window settle at 900x247, where the
        // activity list is a sliver and the floating bars have nothing behind them
        // to refract — glass with nothing to do reads as a flat slab.
        .frame(minWidth: 560, minHeight: 460)
    }
}

struct SharesPane: View {
    let model: MenuModel

    @State private var drafts: [ShareDraft] = []
    @State private var selection: UUID?
    @State private var status: String?
    @State private var testResult: TestOutcome?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // The "Multimedia" share appeared to stop drawing even though
                // `drafts` loaded fine, and .listStyle(.sidebar) was blamed and
                // dropped — but the List was legitimately empty: the app was
                // blocked on a login-Keychain prompt, so loadDrafts() hadn't
                // returned anything yet. Once the password was entered, the row
                // rendered correctly with .listStyle(.sidebar) in place. Restored.
                List(selection: $selection) {
                    ForEach(drafts) { draft in
                        Text(draft.displayName.isEmpty ? "Untitled" : draft.displayName)
                            .tag(draft.id)
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 2) {
                    Button {
                        drafts.append(ShareDraft())
                        selection = drafts.last?.id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a share")

                    Button {
                        drafts.removeAll { $0.id == selection }
                        selection = drafts.first?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected share")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Divider() }
                // safeAreaPadding(.bottom) was tried first: it reads the ambient
                // bottom safe-area inset from the environment and adds that much
                // real padding. It read as zero here and cleared nothing, because
                // HSplitView hosts each of its panes in its own NSHostingView —
                // the safeAreaInset attached to the HSplitView itself insets the
                // split view's own content area, but that inset doesn't cross into
                // a child pane's separately-hosted SwiftUI environment. So there is
                // no ambient inset for safeAreaPadding to pick up down here.
                // Fall back to a fixed bottom padding sized to clear the glass bar
                // outright: the bar is its own HStack padding (~32-40pt) plus a
                // .glassEffect capsule with further internal padding plus the
                // safeAreaInset's own .padding(.bottom, 8), roughly 60-70pt total.
                // 76pt clears that with margin so the buttons are never covered.
                .padding(.bottom, 76)
            }
            // A floor with no ceiling let the List consume the HSplitView: with
            // the sidebar finally populated (see above), it claimed ~710pt of a
            // 900pt window and left the detail Form ~150pt wide, wrapping labels
            // mid-word and truncating field values. Cap the band so the detail
            // form keeps the majority of the width.
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)

            if let index = drafts.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $drafts[index].displayName)
                    TextField("Host", text: $drafts[index].host)
                    TextField("Share", text: $drafts[index].sharePath)
                    TextField("Username", text: $drafts[index].username)
                    SecureField(
                        drafts[index].hasStoredPassword ? "Password (saved)" : "Password",
                        text: Binding(
                            get: { drafts[index].password ?? "" },
                            set: { drafts[index].password = $0.isEmpty ? nil : $0 }
                        )
                    )
                    Toggle("Enabled", isOn: $drafts[index].enabled)
                    Toggle("Read only", isOn: $drafts[index].readOnly)

                    Button("Test connection") { test(drafts[index]) }
                    if let testResult {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: testResult.symbol)
                                .foregroundStyle(testResult.tint)
                            Text(testResult.message)
                                .font(.caption)
                                // Wrap rather than truncate: the useful part of a
                                // NetFS failure is at the end of the sentence.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .formStyle(.grouped)
                .padding()
                .padding(.trailing, 8)
            } else {
                Text("Select a share")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 12) {
                HStack {
                    if let status { Text(status).font(.caption) }
                    Spacer()
                    Button("Revert") {
                        Task { drafts = await model.settings.loadDrafts() }
                    }
                    .buttonStyle(.glass)
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task { drafts = await model.settings.loadDrafts() }
    }

    private func save() {
        Task {
            do {
                try await model.settings.save(drafts)
                drafts = await model.settings.loadDrafts()
                status = "Saved"
            } catch let error as SettingsError {
                if case .invalidDraft(let index, let reason) = error {
                    status = "Row \(index + 1): \(reason)"
                }
            } catch {
                status = "Could not save: \(error)"
            }
        }
    }

    private func test(_ draft: ShareDraft) {
        testResult = TestOutcome.testing
        Task {
            switch await model.settings.test(draft) {
            case .succeeded:
                testResult = .succeeded()
            case .alreadyMounted(let path):
                testResult = .alreadyMounted(at: path)
            case .failed(let failure):
                testResult = .failed("\(failure.reason)")
            }
        }
    }
}

/// What a connection test produced, resolved to what should be drawn. Lives in the
/// view layer because `MountMateCore` must not import SwiftUI.
struct TestOutcome {
    let message: String
    let symbol: String
    let tint: Color

    static let testing = TestOutcome(
        message: "Testing…", symbol: "ellipsis.circle", tint: .secondary
    )

    static func succeeded() -> TestOutcome {
        TestOutcome(message: "Connected", symbol: "checkmark.circle.fill", tint: .green)
    }

    static func alreadyMounted(at path: String) -> TestOutcome {
        TestOutcome(
            message: "Already mounted at \(path)",
            symbol: "checkmark.circle.fill",
            tint: .green
        )
    }

    static func failed(_ reason: String) -> TestOutcome {
        TestOutcome(
            message: "Failed: \(reason)", symbol: "xmark.circle.fill", tint: .red
        )
    }
}

struct GeneralPane: View {
    let model: MenuModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @State private var intervalMinutes = 5.0
    @State private var notifyOnFailure = true
    @State private var notifyOnRecovery = true

    var body: some View {
        Form {
            Toggle("Launch MountMate at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, wanted in
                    do {
                        // Reports the real failure rather than silently reverting:
                        // this needs a properly located, stably signed app, which a
                        // development bundle is not (spec §6, §7).
                        if wanted {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        error = nil
                    } catch {
                        self.error = "\(error.localizedDescription) — this usually needs the installed, signed app."
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Stepper(
                "Check every \(Int(intervalMinutes)) min",
                value: $intervalMinutes, in: 1...60
            )
            .onChange(of: intervalMinutes) { _, minutes in
                Task { await model.preferences.setHealthCheckInterval(.seconds(Int(minutes) * 60)) }
            }

            Toggle("Notify when a share fails", isOn: $notifyOnFailure)
                .onChange(of: notifyOnFailure) { _, enabled in
                    Task {
                        await model.preferences.setNotifyOnFailure(enabled)
                        // Ask only when switching on, and only because someone
                        // clicked: never from a background sweep.
                        if enabled { _ = await UserNotificationNotifier.requestAuthorization() }
                    }
                }
            Toggle("Notify when it recovers", isOn: $notifyOnRecovery)
                .onChange(of: notifyOnRecovery) { _, enabled in
                    Task { await model.preferences.setNotifyOnRecovery(enabled) }
                }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            let seconds = await model.preferences.healthCheckInterval.components.seconds
            intervalMinutes = Double(seconds) / 60
            notifyOnFailure = await model.preferences.notifyOnFailure
            notifyOnRecovery = await model.preferences.notifyOnRecovery
        }
    }
}
