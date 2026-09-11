import Testing
import Foundation
@testable import MountMateCore

private func makeControllers(
    endpoints: [ShareEndpoint] = []
) -> (AppController, InMemoryEndpointStore, InMemoryCredentialStore, SettingsController) {
    let endpointStore = InMemoryEndpointStore(endpoints: endpoints)
    let credentials = InMemoryCredentialStore()
    let app = AppController(
        endpointStore: endpointStore,
        credentialStore: credentials,
        sources: [],
        scheduler: FakeScheduler(limit: 0),
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    let settings = SettingsController(
        appController: app,
        credentialStore: credentials,
        service: FakeMountService(),
        inspector: FakeMountInspector()
    )
    return (app, endpointStore, credentials, settings)
}

@Test func savingAValidDraftPersistsItAndItsPassword() async throws {
    let (app, endpointStore, credentials, settings) = makeControllers()
    await app.start()

    var draft = ShareDraft(id: UUID())
    draft.displayName = "Multimedia"
    draft.host = "192.0.2.10"
    draft.sharePath = "Multimedia"
    draft.username = "nasuser"
    draft.password = "hunter2"

    try await settings.save([draft])

    let stored = try await endpointStore.load()
    #expect(stored.endpoints.count == 1)
    #expect(await credentials.password(for: stored.endpoints[0]) == "hunter2")

    await app.stop()
}

/// One bad row must not cost the good ones — nothing is written at all.
@Test func aSingleInvalidDraftAbortsTheWholeSave() async throws {
    let existing = try makeStoreEndpoint(name: "Multimedia")
    let (app, endpointStore, _, settings) = makeControllers(endpoints: [existing])
    await app.start()

    var good = ShareDraft(existing, hasStoredPassword: false)
    good.displayName = "Renamed"

    var bad = ShareDraft(id: UUID())
    bad.host = "192.0.2.10"
    bad.sharePath = "Exports"
    bad.scheme = "nfs"

    await #expect(throws: SettingsError.self) {
        try await settings.save([good, bad])
    }

    // Unchanged on disk: the rename did not land either.
    let stored = try await endpointStore.load()
    #expect(stored.endpoints.first?.displayName == "Multimedia")

    await app.stop()
}

@Test func loadingDraftsReportsWhichHaveAStoredPassword() async throws {
    let withPassword = try makeStoreEndpoint(name: "Multimedia")
    let withoutPassword = try makeStoreEndpoint(name: "Backup")
    let (app, _, credentials, settings) = makeControllers(
        endpoints: [withPassword, withoutPassword]
    )
    try await credentials.setPassword("hunter2", for: withPassword)
    await app.start()

    let drafts = await settings.loadDrafts()

    #expect(drafts.count == 2)
    #expect(drafts.first(where: { $0.displayName == "Multimedia" })?.hasStoredPassword == true)
    #expect(drafts.first(where: { $0.displayName == "Backup" })?.hasStoredPassword == false)
    // The value itself is never loaded into the form.
    #expect(drafts.allSatisfy { $0.password == nil })

    await app.stop()
}

@Test func editingAHostCarriesThePasswordAcross() async throws {
    let original = try makeStoreEndpoint(name: "Multimedia", host: "192.0.2.10")
    let (app, endpointStore, credentials, settings) = makeControllers(endpoints: [original])
    try await credentials.setPassword("hunter2", for: original)
    await app.start()

    var moved = ShareDraft(original, hasStoredPassword: true)
    moved.host = "192.0.2.20"

    try await settings.save([moved])

    let stored = try await endpointStore.load()
    let newEndpoint = try #require(stored.endpoints.first)
    #expect(newEndpoint.url.host == "192.0.2.20")
    #expect(await credentials.password(for: newEndpoint) == "hunter2")
    #expect(await credentials.password(for: original) == nil)

    await app.stop()
}

/// Save reports which share it refused and why, in words the form can show as they
/// are: the pane selects that share and puts the reason beside Save.
@Test func aRefusedSaveNamesTheShareAndTheFieldToFix() async throws {
    let existing = try makeStoreEndpoint(name: "Multimedia")
    let (app, _, _, settings) = makeControllers(endpoints: [existing])
    await app.start()

    let good = ShareDraft(existing, hasStoredPassword: false)
    var bad = ShareDraft(id: UUID())
    bad.sharePath = "Exports"   // no host

    await #expect(throws: SettingsError.invalidDraft(
        index: 1, reason: ShareDraftProblem.missingHost.message
    )) {
        try await settings.save([good, bad])
    }

    await app.stop()
}
