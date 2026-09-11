import Testing
import Foundation
@testable import MountMateCore

// A person should never read an internal identifier. Settings' Test button showed
// "Failed: authenticationFailed" because it printed the enum case itself.

@Test func everyReasonHasASummaryAPersonCanRead() {
    for reason in MountFailureReason.allCases {
        let summary = reason.summary
        #expect(!summary.isEmpty)
        #expect(summary != String(describing: reason), "\(reason) would show its case name")
        // camelCase is the tell of an identifier leaking out.
        #expect(summary.range(of: "[a-z][A-Z]", options: .regularExpression) == nil, "\(summary)")
        #expect(summary.first?.isUppercase == true, "\(summary)")
    }
}

/// The menu already used these words; one source now serves the menu, the activity log
/// and the Test button, so a failure reads the same wherever it appears.
@Test func theSummariesKeepTheWordsTheMenuAlreadyShows() {
    #expect(MountFailureReason.timedOut.summary == "Timed out")
    #expect(MountFailureReason.noCredential.summary == "No password saved")
    #expect(MountFailureReason.mountpointOccupied.summary == "Mount point in use")
    #expect(MountFailureReason.serverNotResponding.summary == "Server not responding")
}

/// "Failed", as the reason a share failed, told nobody anything.
@Test func anUnknownFailureSaysItIsUnknown() {
    #expect(MountFailureReason.unknown.summary == "Unknown error")
}

// MARK: - Copy that agent recovery made false

/// Written before MountMate could restart the network-mount agent, this remedy told the
/// user MountMate had stopped and asked them to restart the server or the Mac.
@Test func theNotRespondingRemedyDescribesWhatMountMateNowDoes() throws {
    let remedy = try #require(MountFailureReason.serverNotResponding.remedy)
    #expect(remedy.contains("network-mount agent"))
    #expect(!remedy.contains("stopped until it clears"))
}

/// Every time this was seen, the server was accepting connections; the attempts were
/// stuck on this Mac. The notification must not blame the server for it.
@Test func theNotRespondingNotificationDoesNotBlameTheServer() {
    var policy = NotificationPolicy()
    let id = UUID()
    let status = EndpointStatus(
        id: id, displayName: "Multimedia",
        state: .failed(MountFailure(reason: .serverNotResponding)), enabled: true
    )
    _ = policy.evaluate([status])
    let body = policy.evaluate([status]).first?.body ?? ""

    #expect(!body.isEmpty)
    #expect(!body.contains("stopped responding"))
}
