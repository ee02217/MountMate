import Foundation

public enum SettingsError: Error, Equatable {
    /// Which row, and why, so the pane can point at it.
    case invalidDraft(index: Int, reason: String)
}

/// What the Settings pane talks to.
///
/// Save is one ordered operation over the whole list rather than per-row: validate
/// everything, settle credentials, then persist and sweep. A row with a typo
/// therefore costs nothing except that row's correction — the others are never
/// half-written (spec §8).
public actor SettingsController {
    private let appController: AppController
    private let credentialStore: any CredentialStore
    private let mover: CredentialMover
    private let tester: ConnectionTester

    public init(
        appController: AppController,
        credentialStore: any CredentialStore,
        service: any MountService = NetFSMountService(),
        inspector: any MountInspector = SystemMountInspector()
    ) {
        self.appController = appController
        self.credentialStore = credentialStore
        self.mover = CredentialMover(store: credentialStore)
        self.tester = ConnectionTester(service: service, inspector: inspector)
    }

    /// Drafts for every configured share.
    ///
    /// `hasStoredPassword` is resolved here; the password itself is never read into
    /// a draft. A form that could display a stored secret is a form that can leak it.
    public func loadDrafts() async -> [ShareDraft] {
        var drafts: [ShareDraft] = []
        for endpoint in await appController.endpoints {
            let stored = await credentialStore.password(for: endpoint) != nil
            drafts.append(ShareDraft(endpoint, hasStoredPassword: stored))
        }
        return drafts
    }

    public func save(_ drafts: [ShareDraft]) async throws {
        // Validate everything before touching anything.
        var endpoints: [ShareEndpoint] = []
        for (index, draft) in drafts.enumerated() {
            do {
                endpoints.append(try draft.validated())
            } catch {
                let reason = (error as? ShareEndpointError)?.description
                    ?? String(describing: error)
                throw SettingsError.invalidDraft(index: index, reason: reason)
            }
        }

        // Credentials first, then persist. `apply` sweeps as its last act, and a
        // sweep that runs before the password exists fails with `.noCredential` and
        // advances backoff — so a share given its first password here would sit
        // unmounted until the backstop, for no reason the user could see.
        let existing = await appController.endpoints
        for (draft, new) in zip(drafts, endpoints) {
            let old = existing.first { $0.id == new.id }
            try await mover.settle(draft: draft, old: old, new: new)
        }

        try await appController.apply(endpoints)
    }

    /// Uses the draft as typed, not as saved: the point is to check before saving.
    public func test(_ draft: ShareDraft) async -> ConnectionTestResult {
        guard let endpoint = try? draft.validated() else {
            return .failed(MountFailure(reason: .unknown))
        }
        // Spelled out rather than `??`: the right-hand side of a nil-coalescing
        // operator is an autoclosure, which cannot contain an `await`.
        let password: String?
        if let typed = draft.password, !typed.isEmpty {
            password = typed
        } else {
            password = await credentialStore.password(for: endpoint)
        }
        return await tester.test(endpoint, password: password)
    }
}
