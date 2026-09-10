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
    }
}

struct SharesPane: View {
    let model: MenuModel

    @State private var drafts: [ShareDraft] = []
    @State private var selection: UUID?
    @State private var status: String?
    @State private var testResult: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(drafts) { draft in
                        Text(draft.displayName.isEmpty ? "Untitled" : draft.displayName)
                            .tag(draft.id)
                    }
                }
                HStack {
                    Button("+") {
                        drafts.append(ShareDraft())
                        selection = drafts.last?.id
                    }
                    Button("−") {
                        drafts.removeAll { $0.id == selection }
                        selection = drafts.first?.id
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 160)

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

                    HStack {
                        Button("Test connection") { test(drafts[index]) }
                        if let testResult {
                            Text(testResult).font(.caption)
                        }
                    }
                }
                .padding()
            } else {
                Text("Select a share")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        testResult = "Testing…"
        Task {
            switch await model.settings.test(draft) {
            case .succeeded:
                testResult = "Connected"
            case .alreadyMounted(let path):
                testResult = "Already mounted at \(path)"
            case .failed(let failure):
                testResult = "Failed: \(failure.reason)"
            }
        }
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
        .padding()
        .task {
            let seconds = await model.preferences.healthCheckInterval.components.seconds
            intervalMinutes = Double(seconds) / 60
            notifyOnFailure = await model.preferences.notifyOnFailure
            notifyOnRecovery = await model.preferences.notifyOnRecovery
        }
    }
}
