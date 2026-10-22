import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class QuotaSidebarHeightBudgetTests: XCTestCase {
    func testOneNewTPSRowUsesHeadroomThenAdditionalRowsGrowTheFrame() {
        var budget = QuotaSidebarHeightBudget()
        budget.update(contentHeight: 400, rowHeight: 40, expanded: false)
        XCTAssertEqual(budget.targetHeight, 464)
        budget.update(expanded: true)
        budget.update(contentHeight: 440, expanded: true)
        XCTAssertEqual(budget.targetHeight, 464)
        budget.update(contentHeight: 480, expanded: true)
        XCTAssertEqual(budget.targetHeight, 504)
        budget.update(contentHeight: 520, expanded: true)
        XCTAssertEqual(budget.targetHeight, 544)
    }
    func testClosingRearmsExactlyOneRowAndDropsUnusedOldHeight() {
        var budget = QuotaSidebarHeightBudget()
        budget.update(contentHeight: 600, rowHeight: 38, expanded: false)
        budget.update(contentHeight: 400, expanded: true)
        XCTAssertEqual(budget.targetHeight, 662)
        budget.update(expanded: false)
        XCTAssertEqual(budget.targetHeight, 462)
        budget.update(contentHeight: 438, expanded: true)
        XCTAssertEqual(budget.targetHeight, 462)
    }
    func testInitialExpandedMeasurementAlsoReservesOneRowAndRejectsInvalidValues() {
        var budget = QuotaSidebarHeightBudget()
        budget.update(contentHeight: .nan, rowHeight: .infinity, expanded: true)
        XCTAssertNil(budget.targetHeight)
        budget.update(contentHeight: 400.2, rowHeight: 38.2, expanded: true)
        XCTAssertEqual(budget.targetHeight, 464)
        budget.update(contentHeight: -100, rowHeight: -40, expanded: true)
        XCTAssertEqual(budget.targetHeight, 464)
    }
    func testLargeContentClampsToShortSecondaryDisplayWithNegativeOrigin() {
        let area = CGRect(x: -1920, y: -900, width: 1920, height: 560)
        let frames = QuotaSidebarFrames.make(usableFrame: area, edge: .left, expanded: true,
            normalizedY: 0.2, expandedHeight: 1000)
        XCTAssertEqual(frames.rail.height, 560)
        XCTAssertTrue(area.contains(frames.rail))
    }
    @MainActor
    func testExpandedCanvasCanGrowWithoutClippingTallContent() {
        let host = NSView(frame: .zero)
        let canvas = QuotaSidebarCanvasView(host: host, edge: .right)
        canvas.canvasHeight = 900
        canvas.frame = CGRect(x: 1352, y: 100, width: 88, height: 820)
        canvas.layout()
        XCTAssertEqual(host.frame.height, 900)
        XCTAssertEqual(host.frame.midY, canvas.bounds.midY)
        XCTAssertEqual(host.frame.width, 88)
    }
    @MainActor
    func testProductionRailSpendsOneMeasuredRowBeforeResizing() throws {
        let suite = "SidebarHeight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        let now = Date().timeIntervalSince1970
        func seed(_ count: Int) {
            let models = ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra"]
            let samples = (0..<count).map { index in
                ObservedSpeedSample(id: "sample-\(index)", threadID: "fixture", turnID: "turn", itemID: "body-\(index)",
                    model: models[index], startedAt: now - 3, endedAt: now - 1, outputTokens: 100,
                    outputCharacters: 400, outputBytes: 400, chunkCount: 1, durationSeconds: 2,
                    tokensPerSecond: 50, confidence: "high", networkWarning: nil, source: "rollout_body",
                    measurementKind: "completed_body", tokenizer: "o200k_base", bodyPhase: "final_answer")
            }
            monitor.testSeedBodySpeedDisplay(samples: samples, points: [], now: now)
        }
        seed(1)
        let controller = QuotaSidebarController(settings: defaults)
        let store = CodexUsageStore(autoStart: false, continuityDefaults: defaults)
        let quota = AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false)
        let tasks = TaskCompletionMonitor(defaults: defaults)
        let radar = CodexRadarStore(detailRefreshDefaults: defaults)
        let history = QuotaHistoryStore()
        controller.show(store: store, monitor: monitor, quota: quota, tasks: tasks, radar: radar,
                        history: history, edge: .right)
        defer { controller.close() }
        func settle() {
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func snapshot(_ name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["CODEX_SIDEBAR_HEIGHT_PREVIEW"] else { return }
            let view = try XCTUnwrap(controller.railPanel?.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        settle()
        controller.enter(); settle()
        let first = try XCTUnwrap(controller.railPanel).frame.height
        try snapshot("native-1-model.png")
        seed(2); settle()
        let second = try XCTUnwrap(controller.railPanel).frame.height
        try snapshot("native-2-models.png")
        XCTAssertEqual(second, first, accuracy: 1, "The first additional TPS model must spend existing padding")
        seed(3); settle()
        let third = try XCTUnwrap(controller.railPanel).frame.height
        try snapshot("native-3-models.png")
        XCTAssertGreaterThan(third, second + 10, "A second additional model must resize the native frame")
        XCTAssertLessThan(first, 590, "Measured rail should remove legacy empty margins")
        print("SIDEBAR_MEASURED_HEIGHTS \(first),\(second),\(third)")
    }

}
