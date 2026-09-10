import Testing
import Foundation
@testable import MountMateCore

private func endpoint(host: String, share: String, id: UUID) throws -> ShareEndpoint {
    try ShareEndpoint(
        id: id,
        displayName: share,
        url: URL(string: "smb://\(host)/\(share)")!,
        username: "smbshare",
        mountPolicy: .volumes
    )
}

@Test func aTypedPasswordIsStored() async throws {
    let store = InMemoryCredentialStore()
    let mover = CredentialMover(store: store)
    let id = UUID()
    let new = try endpoint(host: "192.168.1.67", share: "Multimedia", id: id)

    var draft = ShareDraft(new, hasStoredPassword: false)
    draft.password = "hunter2"

    try await mover.settle(draft: draft, old: nil, new: new)

    #expect(await store.password(for: new) == "hunter2")
}

@Test func anUnchangedShareWithNoTypedPasswordIsLeftAlone() async throws {
    let store = InMemoryCredentialStore()
    let id = UUID()
    let endpointValue = try endpoint(host: "192.168.1.67", share: "Multimedia", id: id)
    try await store.setPassword("hunter2", for: endpointValue)

    let mover = CredentialMover(store: store)
    let draft = ShareDraft(endpointValue, hasStoredPassword: true)

    try await mover.settle(draft: draft, old: endpointValue, new: endpointValue)

    #expect(await store.password(for: endpointValue) == "hunter2")
}

@Test func changingTheHostMovesThePasswordAndLeavesNoOrphan() async throws {
    let store = InMemoryCredentialStore()
    let id = UUID()
    let old = try endpoint(host: "192.168.1.67", share: "Multimedia", id: id)
    let new = try endpoint(host: "192.168.1.70", share: "Multimedia", id: id)
    try await store.setPassword("hunter2", for: old)

    let mover = CredentialMover(store: store)
    let draft = ShareDraft(new, hasStoredPassword: true)

    try await mover.settle(draft: draft, old: old, new: new)

    #expect(await store.password(for: new) == "hunter2")
    // The point of moving rather than copying: no stale item to puzzle over later.
    #expect(await store.password(for: old) == nil)
}

@Test func aTypedPasswordWinsOverTheMovedOne() async throws {
    let store = InMemoryCredentialStore()
    let id = UUID()
    let old = try endpoint(host: "192.168.1.67", share: "Multimedia", id: id)
    let new = try endpoint(host: "192.168.1.70", share: "Multimedia", id: id)
    try await store.setPassword("old-password", for: old)

    let mover = CredentialMover(store: store)
    var draft = ShareDraft(new, hasStoredPassword: true)
    draft.password = "new-password"

    try await mover.settle(draft: draft, old: old, new: new)

    #expect(await store.password(for: new) == "new-password")
    #expect(await store.password(for: old) == nil)
}

/// Moving when there was never a password must not write an empty one.
@Test func movingWithNothingStoredStoresNothing() async throws {
    let store = InMemoryCredentialStore()
    let id = UUID()
    let old = try endpoint(host: "192.168.1.67", share: "Multimedia", id: id)
    let new = try endpoint(host: "192.168.1.70", share: "Multimedia", id: id)

    let mover = CredentialMover(store: store)
    let draft = ShareDraft(new, hasStoredPassword: false)

    try await mover.settle(draft: draft, old: old, new: new)

    #expect(await store.password(for: new) == nil)
}
