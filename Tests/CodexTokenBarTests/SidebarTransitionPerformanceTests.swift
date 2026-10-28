import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SidebarTransitionPerformanceTests: XCTestCase {
    @MainActor
    func testChangingRateInCollapsedRail() throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_SIDEBAR_RATE_PERF_OUTPUT"] else {
            throw XCTSkip("Opt-in changing-rate sidebar CPU fixture")
        }
        let suite = "SidebarChangingRate-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: true)
        monitor.setPollingActive(false)
        monitor.dataSource = CodexDataSource(codexHome: URL(fileURLWithPath: "/fixture-not-read"), origin: .defaultHome)
        let controller = QuotaSidebarController(settings: defaults)
        controller.show(store: CodexUsageStore(autoStart: false, continuityDefaults: defaults), monitor: monitor,
            quota: AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false),
            tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
            history: QuotaHistoryStore(), edge: .left)
        defer { controller.close(); monitor.setMonitoringEnabled(false) }
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func settle(_ seconds: Double) {
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < seconds { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        }
        settle(0.5)
        let start = CACurrentMediaTime(), beganCPU = cpu()
        var nextUpdate = start, updates = 0, maxGap = 0.0, previous = start
        while CACurrentMediaTime() - start < 4 {
            let now = CACurrentMediaTime()
            maxGap = max(maxGap, now - previous); previous = now
            if now >= nextUpdate {
                let rate = 100 + 90 * sin((now - start) * 2)
                var next = monitor.totalSnapshot
                next.rollingTokensPerSecond = rate
                next.modelRates = [.init(model: "gpt-6-astra", tokensPerSecond: rate * 0.4),
                                   .init(model: "gpt-6.1-sol", tokensPerSecond: rate * 0.6)]
                monitor.totalSnapshot = next
                updates += 1; nextUpdate = now + 0.25
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        let wall = CACurrentMediaTime() - start, spent = cpu() - beganCPU
        let report: [String: Any] = ["collapsed": !controller.interaction.expanded, "updates": updates,
            "wallSeconds": wall, "cpuSeconds": spent, "oneCoreCPUPercent": spent / wall * 100, "maxMainLoopGapMs": maxGap * 1000]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        XCTAssertFalse(controller.interaction.expanded)
        XCTAssertGreaterThanOrEqual(updates, 12)
    }

    /// Opt-in production-view benchmark. Timings are evidence, not flaky CI gates.
    @MainActor
    func testHoverWithAndWithoutUpdatingSpeedPage() throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_SIDEBAR_PERF_OUTPUT"] else {
            throw XCTSkip("Set CODEX_SIDEBAR_PERF_OUTPUT to run the native timing fixture")
        }
        let suite = "SidebarPerf-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        let now = Date().timeIntervalSince1970
        let bucket = Int64(now / 300) * 300
        let models = ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra"]
        var points: [BodySpeedTrendPoint] = []
        for model in models {
            for index in 0..<288 {
                let start = bucket - Int64(index * 300)
                let speed = Double(30 + index % 90)
                points.append(BodySpeedTrendPoint(bucketStart: start, model: model,
                    outputTokens: 500, durationSeconds: 10, sampleCount: 3,
                    tokensPerSecond: speed))
            }
        }
        monitor.testSeedBodySpeedDisplay(samples: [], points: points, now: now)
        let controller = QuotaSidebarController(settings: defaults)
        controller.show(store: CodexUsageStore(autoStart: false, continuityDefaults: defaults), monitor: monitor,
            quota: AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false),
            tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
            history: QuotaHistoryStore(), edge: .left)
        defer { controller.close() }
        let chart = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 850, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        chart.isReleasedWhenClosed = false
        defer { chart.close() }
        func settle(_ seconds: Double) {
            let until = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        }
        var report: [[String: Any]] = []
        for withPage in [false, true] {
            if withPage {
                chart.contentView = NSHostingView(rootView: ScrollView { ObservedSpeedView(monitor: monitor).padding(16) })
                chart.orderFrontRegardless()
            }
            settle(0.6)
            var gaps: [Double] = [], updateCosts: [Double] = [], resizeTimes: [Double] = []
            var visualTimes: [Double] = [], previousVisualFrame: CGRect?
            // Notification delivery is synchronous on the main thread.
            let box = ResizeTimes()
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: controller.railPanel, queue: nil) { _ in box.values.append(CACurrentMediaTime()) }
            for _ in 0..<3 {
                for expanded in [true, false] {
                    let start = CACurrentMediaTime()
                    if expanded { controller.enter() } else { controller.dismiss() }
                    var previous = start, nextUpdate = start
                    while CACurrentMediaTime() - start < 0.65 {
                        let time = CACurrentMediaTime()
                        gaps.append(time - previous); previous = time
                        let visualFrame = controller.presentedRailFrame ?? controller.railPanel?.frame
                        if visualFrame != previousVisualFrame { visualTimes.append(time); previousVisualFrame = visualFrame }
                        if time >= nextUpdate {
                            let update = CACurrentMediaTime()
                            monitor.objectWillChange.send()
                            chart.contentView?.layoutSubtreeIfNeeded()
                            updateCosts.append(CACurrentMediaTime() - update)
                            nextUpdate = time + 0.1
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
                    }
                }
            }
            NotificationCenter.default.removeObserver(observer)
            resizeTimes = zip(box.values.dropFirst(), box.values).map { $0 - $1 }.filter { $0 < 0.2 }
            func stats(_ values: [Double]) -> [String: Double] {
                let sorted = values.sorted()
                return ["count": Double(sorted.count), "p50_ms": (sorted.isEmpty ? 0 : sorted[sorted.count / 2]) * 1000,
                    "p95_ms": (sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]) * 1000,
                    "max_ms": (sorted.last ?? 0) * 1000]
            }
            report.append(["speed_page_visible": withPage, "points": points.count,
                "main_loop": stats(gaps), "refresh": stats(updateCosts), "resize_intervals": stats(resizeTimes),
                "native_resize_count": box.values.count, "visual_frame_count": visualTimes.count,
                "visual_frame_intervals": stats(zip(visualTimes.dropFirst(), visualTimes).map { $0 - $1 }.filter { $0 < 0.2 })])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("SIDEBAR_PERF_REPORT \(output)")
    }
}

private final class ResizeTimes: @unchecked Sendable {
    // Only used synchronously on the test's main thread.
    var values: [Double] = []
}
