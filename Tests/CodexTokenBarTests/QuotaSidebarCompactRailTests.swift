import AppKit
import SwiftUI
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

    func testPeekHeightFitsAnEmptyTaskStateAndGrowsForActualRows() {
        XCTAssertEqual(QuotaSidebarPeekRegion.preferredHeight(for: .tasks), 154)
        XCTAssertEqual(QuotaSidebarPeekRegion.preferredHeight(for: .tasks, taskRows: 20), 320)
        XCTAssertEqual(QuotaSidebarPeekRegion.preferredHeight(for: .quota("codex"), quotaCount: 1), 152)
        XCTAssertEqual(QuotaSidebarPeekRegion.preferredHeight(for: .quota("antigravity"), quotaCount: 4), 320)
        XCTAssertEqual(QuotaSidebarPeekRegion.preferredHeight(for: .radar), 180)
    }

    func testPeekGapDoesNotTrapThePointerInUnusedDesktopCorners() {
        let rail = CGRect(x: 1000, y: 200, width: 28, height: 200)
        let peek = CGRect(x: 734, y: 300, width: 258, height: 280)
        XCTAssertTrue(QuotaSidebarPeekRegion.contains(CGPoint(x: 996, y: 350), rail: rail, peek: peek))
        XCTAssertFalse(QuotaSidebarPeekRegion.contains(CGPoint(x: 800, y: 250), rail: rail, peek: peek))
        XCTAssertFalse(QuotaSidebarPeekRegion.contains(CGPoint(x: 1010, y: 500), rail: rail, peek: peek))
        XCTAssertTrue(QuotaSidebarPeekRegion.contains(CGPoint(x: 800, y: 500), rail: rail, peek: peek))
    }

    @MainActor
    func testCompactCanvasDoesNotPaintAnOpaqueBackingOverSwiftUITransparency() {
        let canvas = QuotaSidebarCanvasView(host: NSView(), edge: .right)
        XCTAssertEqual(canvas.layer?.backgroundColor?.alpha, 0)
        canvas.setFrameSize(NSSize(width: QuotaSidebarLayout.compactWidth, height: 220))
        XCTAssertTrue(canvas.dragHandle.isHidden)
    }
    @MainActor
    func testProductionCompactRailRendersGroupedPoolsTasksAndRadar() throws {
        let items: [QuotaSidebarItem] = [.speed, .tasks, .quota("codex"), .quota("antigravity"), .models, .radar]
        let quotas = [ClientQuotaItem(id: "codex:7d", client: "codex", window: "7d", remaining: 71.5, resetsAt: nil, source: "fixture", status: "")] +
            ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].enumerated().map { index, id in
                ClientQuotaItem(id: "antigravity:" + id, client: "antigravity", window: id,
                    remaining: [82.5, 60, 9.5, 42][index], resetsAt: nil, source: "fixture", status: "")
            }
        let root = QuotaSidebarCompactRail(items: items, quotas: quotas, rateFraction: 0.48,
            rateText: "48 tok/s", tpsText: "35.5 tok/s",
            summary: RunningThreadSummary(main: 2, subagents: 3, updatedAt: Date(), freshness: .fresh),
            shares: [], radarActive: true, colors: [:], hovered: nil, onHover: { _ in }, onOpen: { _ in })
            .background(Color.black.opacity(0.72))
        let height = QuotaSidebarCompactRail.height(items, available: 900)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: QuotaSidebarLayout.compactWidth, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let colored = (0..<bitmap.pixelsWide).reduce(0) { count, x in
            count + (0..<bitmap.pixelsHigh).filter { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return max(color.redComponent, color.greenComponent, color.blueComponent) > 0.3 &&
                    max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15
            }.count
        }
        XCTAssertGreaterThan(colored, 60, "The compact view must draw actual colored module glyphs")
        if let directory = ProcessInfo.processInfo.environment["TOKENBAR_DISCOVERY_RENDER_DIR"] ?? ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("production-compact-rail.png"))
        }
    }

    @MainActor
    func testHoverPeekKeepsRailCompactAndClickReusesTaskDetail() throws {
        let suite = "ProductionRailPeek-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuotaSidebarController(settings: defaults)
        controller.show(store: CodexUsageStore(autoStart: false, continuityDefaults: defaults),
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false),
            tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
            history: QuotaHistoryStore(), edge: .right)
        defer { controller.close() }
        guard let rail = controller.railPanel, let screen = rail.screen else {
            throw XCTSkip("A native display is required to validate popup geometry")
        }
        controller.hover(.tasks)
        let peek = try XCTUnwrap(controller.peekPanel)
        XCTAssertTrue(peek.isVisible)
        XCTAssertFalse(controller.interaction.expanded, "Hover must not expand the entire sidebar")
        XCTAssertNil(controller.interaction.detail)
        XCTAssertEqual(controller.hoveredItem, .tasks)
        XCTAssertTrue(screen.visibleFrame.contains(peek.frame))
        if let directory = ProcessInfo.processInfo.environment["TOKENBAR_DISCOVERY_RENDER_DIR"] ?? ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"], let host = peek.contentView {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("production-task-peek.png"))
        }
        controller.select(.tasks)
        XCTAssertFalse(peek.isVisible)
        XCTAssertNil(controller.hoveredItem)
        XCTAssertTrue(controller.interaction.expanded)
        XCTAssertEqual(controller.interaction.detail, .tasks)
        controller.dismiss()
        XCTAssertFalse(controller.interaction.expanded)
    }

}
