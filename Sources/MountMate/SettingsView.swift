import SwiftUI
import ServiceManagement
import Security
import MountMateCore

struct SettingsView: View {
    let model: MenuModel

    var body: some View {
        // The Settings scene sizes the window to each tab's minimum when switching, so
        // each minimum is the size that tab actually opens at.
        TabView {
            SharesPane(model: model)
                .frame(minWidth: 760, idealWidth: 820, minHeight: 460, idealHeight: 540)
                .tabItem { Label("Shares", systemImage: "externaldrive") }
            GeneralPane(model: model)
                // Sized to its content, like the General tab of any Apple app: a
                // short form in a tall window reads as unfinished.
                .frame(width: 520, height: 244)
                .tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsPane(model: model)
                .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 540)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
    }
}

struct SharesPane: View {
    let model: MenuModel

    @State private var drafts: [ShareDraft] = []
    @State private var loaded = false
    @State private var selection: UUID?
    @State private var status: SaveStatus?
    @State private var clearSaved: Task<Void, Never>?
    @State private var testResult: TestOutcome?

    var body: some View {
        HSplitView {
            sidebar
                // A floor and a ceiling: without the ceiling the list claims most of
                // the window and the form is left too narrow to read.
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 220)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            drafts = await model.settings.loadDrafts()
            loaded = true
            selectFirstIfNeeded()
        }
        // A test result belongs to the share it ran against, not whichever share is
        // selected next.
        .onChange(of: selection) { testResult = nil }
        // A refusal describes the values Save saw; once they change, it is out of date.
        // Only errors: a reload after a successful Save changes the drafts too, and
        // must not wipe the "Saved" it just earned.
        .onChange(of: drafts) {
            if status?.isError == true { status = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Shares") {
                    ForEach(drafts) { draft in
                        Label(
                            draft.displayName.isEmpty ? "Untitled" : draft.displayName,
                            systemImage: "externaldrive"
                        )
                        .tag(draft.id)
                    }
                }
            }
            .listStyle(.sidebar)

            addRemoveBar
        }
    }

    private var addRemoveBar: some View {
        HStack(spacing: 2) {
            Button {
                drafts.append(ShareDraft())
                selection = drafts.last?.id
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("Add a share")
            // A draft added before the load lands would be overwritten by it.
            .disabled(!loaded)

            Button {
                drafts.removeAll { $0.id == selection }
                selection = drafts.first?.id
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .help("Remove the selected share")
            .disabled(selection == nil)

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Detail

    /// The action row stays put whatever the pane above it shows, so removing the
    /// last share can still be saved.
    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                if !loaded {
                    // loadDrafts() waits on the login Keychain when it is locked, so
                    // this can be on screen for as long as the system prompt is. It
                    // must not claim anything about the shares while it waits.
                    ProgressView("Loading shares…")
                        .controlSize(.small)
                } else if let index = drafts.firstIndex(where: { $0.id == selection }) {
                    form(for: index)
                } else if drafts.isEmpty {
                    ContentUnavailableView {
                        Label("No Shares", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Click + to add a network share.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Share Selected", systemImage: "externaldrive")
                    } description: {
                        Text("Select a share to edit it.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionRow
        }
    }

    private func form(for index: Int) -> some View {
        Form {
            Section {
                TextField("Name", text: $drafts[index].displayName)
            }

            Section("Server") {
                TextField("Host", text: $drafts[index].host)
                TextField("Share", text: $drafts[index].sharePath)
                TextField("Username", text: $drafts[index].username)
                // A bare SecureField renders like the TextFields above it in a grouped
                // form — label leading, value trailing. The prompt carries whether a
                // password is already stored, so the label never changes.
                SecureField(
                    "Password",
                    text: Binding(
                        get: { drafts[index].password ?? "" },
                        set: { drafts[index].password = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(drafts[index].hasStoredPassword ? "Saved in Keychain" : "Required")
                )
            }

            Section {
                Toggle("Enabled", isOn: $drafts[index].enabled)
                Toggle("Read only", isOn: $drafts[index].readOnly)
            }

            Section {
                LabeledContent("Connection") {
                    Button("Test") { test(drafts[index]) }
                }
            } footer: {
                if let testResult {
                    Label {
                        // Wraps rather than truncates: a remedy is a sentence or two.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(testResult.message)
                            if let detail = testResult.detail {
                                Text(detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: testResult.symbol)
                            .foregroundStyle(testResult.tint)
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Beneath the form rather than floating over it: a form this short never
    /// scrolls, so a floating bar would float over nothing.
    private var actionRow: some View {
        HStack(spacing: 8) {
            if let status {
                Label {
                    Text(status.text)
                        .foregroundStyle(status.isError ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: status.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? .red : .green)
                }
                .font(.callout)
            }
            Spacer()
            Button("Revert") { revert() }
                .disabled(!loaded)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: Actions

    /// Keeps the detail pane from sitting empty while there are shares to show.
    private func selectFirstIfNeeded() {
        if !drafts.contains(where: { $0.id == selection }) {
            selection = drafts.first?.id
        }
    }

    private func revert() {
        Task {
            drafts = await model.settings.loadDrafts()
            clearSaved?.cancel()
            status = nil
            selectFirstIfNeeded()
        }
    }

    private func save() {
        Task {
            do {
                try await model.settings.save(drafts)
                drafts = await model.settings.loadDrafts()
                selectFirstIfNeeded()
                showSaved()
            } catch let error as SettingsError {
                if case .invalidDraft(let index, let reason) = error {
                    // Put the refused share on screen, so the field to fix is in view
                    // even if a different share was selected when Save was pressed.
                    if drafts.indices.contains(index) { selection = drafts[index].id }
                    status = .failed("Couldn't save \u{201C}\(Self.name(of: drafts, at: index))\u{201D}. \(reason)")
                }
            } catch let error as CredentialStoreError {
                status = .failed(Self.describe(error))
            } catch {
                status = .failed("Couldn't save your changes. \(error.localizedDescription)")
            }
        }
    }

    /// "Saved" says what just happened, so it goes away after a moment rather than
    /// sitting beside the button describing an edit made long ago.
    private func showSaved() {
        status = .saved
        clearSaved?.cancel()
        clearSaved = Task {
            try? await Task.sleep(for: .seconds(3))
            if status?.isError == false { status = nil }
        }
    }

    /// The name the sidebar shows for that share.
    private static func name(of drafts: [ShareDraft], at index: Int) -> String {
        guard drafts.indices.contains(index), !drafts[index].displayName.isEmpty else {
            return "Untitled"
        }
        return drafts[index].displayName
    }

    /// The Keychain's own explanation of the status, rather than the raw number.
    private static func describe(_ error: CredentialStoreError) -> String {
        switch error {
        case .unexpectedStatus(let status):
            let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
            return "Couldn't store the password in the Keychain: \(reason)"
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
                testResult = .failed(failure)
            }
        }
    }
}

/// What the last Save did, shown beside the Save button.
struct SaveStatus {
    let text: String
    let isError: Bool

    static let saved = SaveStatus(text: "Saved", isError: false)
    static func failed(_ text: String) -> SaveStatus { SaveStatus(text: text, isError: true) }
}

/// What a connection test produced, resolved to what should be drawn. Lives in the
/// view layer because `MountMateCore` must not import SwiftUI.
struct TestOutcome {
    let message: String
    let symbol: String
    let tint: Color
    /// What to do about it, when there is something to do — shown under the message.
    var detail: String? = nil

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

    /// The reason in words a person can read, never the enum case, and the remedy
    /// beneath it when the failure carries one.
    static func failed(_ failure: MountFailure) -> TestOutcome {
        TestOutcome(
            message: failure.reason.summary,
            symbol: "xmark.circle.fill",
            tint: .red,
            detail: failure.remedy
        )
    }
}

struct GeneralPane: View {
    let model: MenuModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @State private var intervalMinutes = 5
    @State private var notifyOnFailure = true
    @State private var notifyOnRecovery = true

    var body: some View {
        Form {
            Section {
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
            }

            Section {
                Picker("Check shares", selection: $intervalMinutes) {
                    ForEach(intervalChoices, id: \.self) { minutes in
                        Text(Self.describe(minutes)).tag(minutes)
                    }
                }
                .onChange(of: intervalMinutes) { _, minutes in
                    Task { await model.preferences.setHealthCheckInterval(.seconds(minutes * 60)) }
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
        }
        .formStyle(.grouped)
        .task {
            let seconds = await model.preferences.healthCheckInterval.components.seconds
            intervalMinutes = max(1, Int(seconds) / 60)
            notifyOnFailure = await model.preferences.notifyOnFailure
            notifyOnRecovery = await model.preferences.notifyOnRecovery
        }
    }

    private static let intervals = [1, 2, 5, 10, 15, 30, 60]

    /// The presets, plus the stored value if it is not one of them — an interval set
    /// before the presets existed stays selectable instead of being quietly changed.
    private var intervalChoices: [Int] {
        Self.intervals.contains(intervalMinutes)
            ? Self.intervals
            : (Self.intervals + [intervalMinutes]).sorted()
    }

    private static func describe(_ minutes: Int) -> String {
        switch minutes {
        case 1: return "Every Minute"
        case 60: return "Every Hour"
        default: return "Every \(minutes) Minutes"
        }
    }
}
