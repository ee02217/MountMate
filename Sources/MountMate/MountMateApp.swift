import SwiftUI
import AppKit
import MountMateCore

@main
struct MountMateApp: App {
    @State private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.presentation.iconSymbolName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Bridges the controller's snapshot stream onto the main actor.
///
/// Deliberately thin: every decision about what to draw was made by
/// `MenuPresentation`, which is tested. This only moves values.
@MainActor
@Observable
final class MenuModel {
    private(set) var presentation = MenuPresentation(statuses: [])

    private let controller: AppController
    let settings: SettingsController
    let activityLog: FileActivityLog
    /// Held as the protocol, not the concrete struct: `UserDefaultsPreferences` is
    /// synchronous, so calling it directly makes every `await` in the Settings pane a
    /// warning. Through the existential the requirements really are async.
    let preferences: any PreferencesStore
    private var pump: Task<Void, Never>?
    private let instanceLock: InstanceLock

    init() {
        // Before anything touches a mount. A second copy racing the first is what
        // produced /Volumes/Multimedia-1 and took a Plex library offline (spec §9.1).
        guard let lock = InstanceLock(path: InstanceLock.defaultPath()) else {
            let alert = NSAlert()
            alert.messageText = "MountMate is already running"
            alert.informativeText = """
                Another copy of MountMate is running — look for its icon in the menu \
                bar. Two copies can fight over the same share and mount it in the \
                wrong place.
                """
            alert.runModal()
            NSApplication.shared.terminate(nil)
            fatalError("unreachable: terminate(_:) does not return")
        }
        self.instanceLock = lock

        let log = FileActivityLog(directory: JSONEndpointStore.defaultDirectory())
        self.activityLog = log

        let preferences: any PreferencesStore = UserDefaultsPreferences()
        self.preferences = preferences
        let notifier = PreferenceGatedNotifier(
            wrapping: UserNotificationNotifier(), preferences: preferences
        )

        // One recovery for both mount paths, so the restart cooldown is shared: the
        // engine's attempts and the Test button queue behind the same agent.
        let recovery = AgentRecovery(
            reachability: TCPReachability(),
            resetter: NetAuthAgentResetter(),
            log: log
        )
        let service = RecoveringMountService(wrapping: NetFSMountService(), recovery: recovery)

        let controller = AppController(
            endpointStore: JSONEndpointStore(directory: JSONEndpointStore.defaultDirectory()),
            credentialStore: KeychainCredentialStore(),
            sources: [
                NetworkTriggerSource(),
                WakeTriggerSource(),
                BackstopTimerSource(interval: { await preferences.healthCheckInterval }),
            ],
            service: service,
            log: log,
            notifier: notifier
        )
        self.controller = controller
        self.settings = SettingsController(
            appController: controller,
            credentialStore: KeychainCredentialStore(),
            service: service
        )

        // No Info.plist yet (spec §8, Development bundle), so LSUIElement cannot do
        // this. Until milestone 7 assembles the bundle, ask for it at runtime.
        NSApplication.shared.setActivationPolicy(.accessory)

        pump = Task { [controller] in
            await controller.start()
            for await snapshot in await controller.statuses {
                await MainActor.run { self.presentation = MenuPresentation(statuses: snapshot) }
            }
        }
    }

    func toggle(_ id: UUID) {
        Task { [controller] in try? await controller.toggle(id) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// Forwarding accessors for the Diagnostics pane: `controller` stays private so
    /// the views cannot reach past the model into the actor graph.
    func controllerLoad() async -> EndpointLoad { await controller.lastLoad }
    func controllerPolicy() async -> CredentialAccessPolicy { await controller.accessPolicy }
}
