import Testing
import Foundation
@testable import MountMateCore

@Test func theReportNamesThePermissivePolicy() throws {
    let report = DiagnosticsReport(
        appVersion: "0.1-dev",
        systemVersion: "26.5.2",
        accessPolicy: .permissive,
        load: EndpointLoad(endpoints: [try makeStoreEndpoint()]),
        entries: []
    )
    let text = report.text()

    // Spec §6: the fallback must be visible, never silent.
    #expect(text.contains("permissive"))
    #expect(text.contains("0.1-dev"))
    #expect(text.contains("26.5.2"))
}

@Test func theReportListsSharesWithoutAnySecret() throws {
    let report = DiagnosticsReport(
        appVersion: "0.1-dev",
        systemVersion: "26.5.2",
        accessPolicy: .permissive,
        load: EndpointLoad(endpoints: [try makeStoreEndpoint(name: "Multimedia")]),
        entries: []
    )
    let text = report.text().lowercased()

    #expect(text.contains("multimedia"))
    #expect(text.contains("smbshare"))
    // Passwords live only in the Keychain and must never reach a pasteboard.
    #expect(!text.contains("password"))
    #expect(!text.contains("hunter2"))
}

@Test func theReportSurfacesSkippedAndQuarantinedEntries() throws {
    let report = DiagnosticsReport(
        appVersion: "0.1-dev",
        systemVersion: "26.5.2",
        accessPolicy: .permissive,
        load: EndpointLoad(
            endpoints: [],
            skipped: [SkippedEndpoint(index: 1, reason: "unsupported scheme \"nfs\"")],
            quarantined: URL(fileURLWithPath: "/tmp/endpoints.json.corrupt-x")
        ),
        entries: []
    )
    let text = report.text()

    // Both have existed since milestone 3 with nothing ever reading them.
    #expect(text.contains("nfs"))
    #expect(text.contains("endpoints.json.corrupt-x"))
}

@Test func theReportIncludesRecentActivity() {
    let report = DiagnosticsReport(
        appVersion: "0.1-dev",
        systemVersion: "26.5.2",
        accessPolicy: .permissive,
        load: EndpointLoad(endpoints: []),
        entries: [
            ActivityEntry(
                timestamp: Date(timeIntervalSince1970: 0),
                category: .mount,
                share: "Multimedia",
                message: "failed — host unreachable"
            )
        ]
    )
    #expect(report.text().contains("host unreachable"))
}
