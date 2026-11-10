import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexConnectionModeTests: XCTestCase {
    func testSharedConnectionModeCases() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-connection-mode.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        for item in cases {
            XCTAssertEqual(CodexConnectionMode.classify(config: item["config"] as? String,
                auth: item["auth"] as? [String: Any]).rawValue, item["expected"] as? String, item["name"] as? String ?? "")
        }
    }

    func testApiProjectionHasNoSubscriptionWindowOrResetCredits() {
        let value = AccountQuotaSnapshot.apiConnection
        let missing = ClientQuotaReading(client: "claudeCode", state: "missing", source: "local", windows: [], notice: "")
        let items = ClientQuotaProjection.items(codex: value, localReadings: [], includeFiveHour: true)
        XCTAssertEqual(items.map(\.id), ["codex:api"])
        XCTAssertNil(items.first?.remaining)
        XCTAssertFalse(value.isAvailable)
        XCTAssertNil(value.resetCreditsAvailableCount)
        XCTAssertTrue(value.diagnostics.isEmpty)
    }
}
