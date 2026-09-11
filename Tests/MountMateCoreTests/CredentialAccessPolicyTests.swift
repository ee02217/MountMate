import Testing
@testable import MountMateCore

// macOS partitions every Keychain item by the code that
// created it. Signed with a team, the partition is the team — stable across builds.
// Without one, it is this exact binary's cdhash, so every rebuild is a stranger.

@Test func aTeamSignedAppIsRestrictedToItself() {
    #expect(CredentialAccessPolicy(teamIdentifier: "GLS94R3UX4") == .appRestricted)
}

@Test func anAppWithoutATeamIsBoundToOneBuild() {
    #expect(CredentialAccessPolicy(teamIdentifier: nil) == .buildBound)
}

/// An unsigned or ad-hoc signature can report an empty team rather than none.
@Test func anEmptyTeamIdentifierCountsAsNone() {
    #expect(CredentialAccessPolicy(teamIdentifier: "") == .buildBound)
}
