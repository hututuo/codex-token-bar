import XCTest
@testable import CodexTokenBar

final class ClientUsageDataLocationTests: XCTestCase {
    func testProductionKeepsItsEstablishedLedgerAndPreviewNeverSharesIt() {
        let support = URL(fileURLWithPath: "/isolated-test-support")
        let prod = ClientUsageDataLocation.databaseURL(applicationSupport: support, bundleIdentifier: "local.codex.token-bar")
        XCTAssertEqual(prod.path, "/isolated-test-support/CodexTokenBar/multi-client-usage.sqlite")
        let preview = ClientUsageDataLocation.databaseURL(applicationSupport: support, bundleIdentifier: "local.codex.token-bar.multiclient-preview")
        XCTAssertNotEqual(preview, prod)
        XCTAssertTrue(preview.path.contains("/Previews/local.codex.token-bar.multiclient-preview/"))
        XCTAssertEqual(ClientUsageDataLocation.databaseURL(applicationSupport: support, bundleIdentifier: nil), prod)
    }
}
