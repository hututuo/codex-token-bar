import AppKit
import XCTest
@testable import CodexTokenBar

final class QuotaSidebarCompactRailTests: XCTestCase {
    func testGroupedClientsHaveStableHeightRegardlessOfNumberOfQuotaWindows() {
        // Antigravity's four observations share one tile; they must not each
        // allocate another 46pt track as in the old compact rail.
        let items: [QuotaSidebarItem] = [.speed, .tasks, .quota("codex"), .quota("antigravity"), .models, .radar]
        XCTAssertEqual(QuotaSidebarCompactRail.height(items, available: 900), 261)
        XCTAssertEqual(QuotaSidebarCompactRail.height(items, available: 180), 180)
        XCTAssertTrue(QuotaSidebarItem.radar.hasCompactRepresentation)
        XCTAssertFalse(QuotaSidebarItem.clientUsage.hasCompactRepresentation)
    }

    func testPoolPeriodColorsUseStableIDsAndKeepFractionalValues() {
        let short = ClientQuotaItem(id: "antigravity:gemini-5h", client: "antigravity", window: "Gemini · 5小时", remaining: 62.5, resetsAt: nil, source: "local", status: "")
        let weekly = ClientQuotaItem(id: "antigravity:3p-weekly", client: "antigravity", window: "第三方 · 7天", remaining: nil, resetsAt: nil, source: "local", status: "未知")
        XCTAssertEqual(short.fill, "#B6EF75")
        XCTAssertEqual(weekly.fill, "#B4ACFF")
        XCTAssertEqual(short.value, "62.5%")
        XCTAssertEqual(weekly.value, "—")
    }

    @MainActor
    func testCompactCanvasDoesNotPaintAnOpaqueBackingOverSwiftUITransparency() {
        let canvas = QuotaSidebarCanvasView(host: NSView(), edge: .right)
        XCTAssertEqual(canvas.layer?.backgroundColor?.alpha, 0)
        canvas.setFrameSize(NSSize(width: QuotaSidebarLayout.compactWidth, height: 220))
        XCTAssertTrue(canvas.dragHandle.isHidden)
    }
}
