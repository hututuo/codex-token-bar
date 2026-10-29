import XCTest
@testable import CodexTokenBar

final class DashboardClientOrderTests: XCTestCase {
    func testCodexStaysFirstAndOtherClientIdentitiesRemainDistinct() {
        XCTAssertEqual(DashboardClientOrder.sorted(["opencode","codex","claudeDesktop","claudeCode"]),["codex","claudeCode","claudeDesktop","opencode"])
        XCTAssertEqual(DashboardClientOrder.sorted(["codex"]),["codex"])
        XCTAssertEqual(DashboardClientOrder.sorted([]),[])
        XCTAssertEqual(DashboardClientOrder.sorted(["gemini","claudeCode"]),["claudeCode","gemini"])
    }
}
