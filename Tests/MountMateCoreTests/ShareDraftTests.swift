import Testing
import Foundation
@testable import MountMateCore

@Test func aDraftBuiltFromAnEndpointRoundTrips() throws {
    let endpoint = try makeStoreEndpoint(name: "Multimedia", host: "192.168.1.67")
    let draft = ShareDraft(endpoint, hasStoredPassword: true)

    #expect(draft.host == "192.168.1.67")
    #expect(draft.sharePath == "Multimedia")
    #expect(draft.username == "smbshare")
    #expect(draft.scheme == "smb")
    #expect(draft.hasStoredPassword)

    let rebuilt = try draft.validated()
    #expect(rebuilt.id == endpoint.id)
    #expect(rebuilt.url == endpoint.url)
    #expect(rebuilt.username == endpoint.username)
}

@Test func aBlankDraftIsInvalidUntilItHasAHostAndShare() {
    var draft = ShareDraft(id: UUID())
    #expect(throws: (any Error).self) { try draft.validated() }

    draft.host = "192.168.1.67"
    #expect(throws: (any Error).self) { try draft.validated() }

    draft.sharePath = "Multimedia"
    #expect(throws: Never.self) { try draft.validated() }
}

/// The form must be allowed to hold an unsupported scheme while it is being typed;
/// validation is what refuses it, with the same error the file loader gives.
@Test func anUnsupportedSchemeFailsValidationNotConstruction() {
    var draft = ShareDraft(id: UUID())
    draft.host = "192.168.1.67"
    draft.sharePath = "Exports"
    draft.scheme = "nfs"

    #expect(throws: ShareEndpointError.unsupportedScheme("nfs")) {
        try draft.validated()
    }
}

@Test func identityFieldsAreHostShareUsernameAndScheme() throws {
    let base = ShareDraft(try makeStoreEndpoint(), hasStoredPassword: false)

    var renamed = base
    renamed.displayName = "Media Library"
    renamed.enabled = false
    renamed.readOnly = true
    // Cosmetic and behavioural changes must never move a credential.
    #expect(!renamed.identityDiffers(from: base))

    for mutate in [
        { (d: inout ShareDraft) in d.host = "192.168.1.70" },
        { (d: inout ShareDraft) in d.sharePath = "Backup" },
        { (d: inout ShareDraft) in d.username = "other" },
        { (d: inout ShareDraft) in d.scheme = "afp" },
    ] {
        var changed = base
        mutate(&changed)
        #expect(changed.identityDiffers(from: base))
    }
}

/// A share path pasted with slashes is ordinary; it must not become a different key
/// from the same path typed without them.
@Test func theSharePathIsNormalised() throws {
    var draft = ShareDraft(id: UUID())
    draft.host = "192.168.1.67"
    draft.username = "smbshare"
    draft.sharePath = "/Multimedia/"

    let endpoint = try draft.validated()
    #expect(endpoint.url.path == "/Multimedia")
}
