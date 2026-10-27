import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class ModelUsageRedrawPerformanceTests: XCTestCase {
    @MainActor
    func testRepeatedRateUpdatesInProductionFloatingCard() throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_MODEL_REDRAW_PERF_OUTPUT"] else {
            throw XCTSkip("Opt-in native scroll and model-cost redraw fixture")
        }
        let breakdown = TokenCacheBreakdown(inputTokens: 100_000, cachedInputTokens: 70_000,
            outputTokens: 20_000, reasoningOutputTokens: 0, totalTokens: 120_000, calls: 3)
        let models = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-sol",
                      "gpt-5.6-luna", "gpt-5.4", "gpt-5.5", "gpt-5.3-codex"]
        let rows = models.map { model in
            ModelTokenBreakdown(model: model, breakdown: Array(repeating: breakdown, count: 8).combined,
                pricePeriods: (0..<8).map { .init(model: model,
                    start: Date(timeIntervalSince1970: 1_792_000_000 + Double($0)), breakdown: breakdown) })
        }
        func snapshot(_ rate: Double) -> TokenDisplaySnapshot {
            .init(title: "Synthetic", status: "Synthetic", rate: rate, consumedTokens: 0,
                  todayTokens: 0, todayRequests: 0, todayModelBreakdowns: rows,
                  quota: .empty, updatedAt: Date(timeIntervalSince1970: 1_792_000_000))
        }
        let visibility = FloatingPanelContentVisibility(showRateAndBar: true, showUsageStatus: false,
            showMetrics: false, showTodayModelShare: true, showTodayModelCost: true,
            showQuota: false, showRadar: false)
        let host = NSHostingView(rootView: TokenDisplayCard(snapshot: snapshot(100), radarSnapshot: nil,
            visibility: visibility, onClose: nil))
        let window = NSWindow(contentRect: .init(x: 160, y: 120, width: 350, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var costs: [Double] = []
        for i in 0..<30 {
            let start = CACurrentMediaTime()
            host.rootView = TokenDisplayCard(snapshot: snapshot(Double(100 + i)), radarSnapshot: nil,
                visibility: visibility, onClose: nil)
            host.layoutSubtreeIfNeeded()
            costs.append((CACurrentMediaTime() - start) * 1_000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let sorted = costs.sorted()
        let report: [String: Any] = ["updates": costs.count, "models": models.count, "pricePeriodsPerModel": 8,
            "p50_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count) * 0.95)],
            "max_ms": sorted.last!, "sum_ms": costs.reduce(0, +)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(costs.count, 30)
    }
}
