import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

/// Opt-in isolated window; never launches the app, opens user data or changes its preferences.
final class ChartGuideScrollPerformanceTests: XCTestCase {
    @MainActor
    func testGuideDuringScroll() async throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_GUIDE_SCROLL_PERF"] else {
            throw XCTSkip("Set CODEX_GUIDE_SCROLL_PERF for isolated native scroll sampling")
        }
        let suite = "TokenBar.ScrollProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fullChart = ProcessInfo.processInfo.environment["CODEX_SCROLL_CHART"] == "1"
        let bins = (0..<8640).map { index in
            BinUsage(start: Date(timeIntervalSince1970: 1_792_848_000 + Double(index * 300)),
                tokens: 10000 + index % 13 * 2000, calls: index % 4)
        }
        let host = NSHostingView(rootView: ScrollView {
            InterfaceScaledContainer(scale: 1, visualWidth: 1000) {
              LazyVStack(spacing: 18) {
                Color.clear.frame(height: 100)
                if ProcessInfo.processInfo.environment["CODEX_SCROLL_HEATMAP"] == "1" {
                    TokenHeatmap(dailyUsage: (0..<365).map { index in
                        DayUsage(date: Date(timeIntervalSince1970: 1_761_350_400 + Double(index * 86400)),
                            tokens: 10000 + index % 17 * 2000, calls: index % 4)
                    }, cacheDaily: [], quotaDaily: [], mode: .daily)
                }
                if fullChart {
                    RecentUsageChart(bins: bins, hourlyBins: [], cacheRecentBins: [], cacheHourlyBins: [],
                        quotaRecentBins: [], quotaHourlyBins: [])
                } else {
                    RecentChartInteractionGuide()
                }
                ForEach(0..<20) { i in
                    HStack { Text("Isolated dashboard row \(i)"); Spacer(); Text("43.2 TPS") }
                        .padding(20).background(Color.gray.opacity(0.08))
                }
              }.padding(20)
            }
        }.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: .init(x: 160, y: 160, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Token Bar · isolated scroll performance probe"
        window.isReleasedWhenClosed = false
        window.contentView = host
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        if ProcessInfo.processInfo.environment["CODEX_SCROLL_FOCUS_WAIT"] == "1" {
            for _ in 0..<30 where !window.occlusionState.contains(.visible) {
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard window.occlusionState.contains(.visible) else {
            throw XCTSkip("Probe is occluded: visible=\(window.isVisible), active=\(NSApp.isActive), window=\(window.windowNumber), policy=\(NSApp.activationPolicy().rawValue)")
        }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        let scroll = try XCTUnwrap(findScroll(host))
        func cpuSeconds() -> Double {
            var value = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
            return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
        }
        let cpuStart = cpuSeconds()
        let wallStart = CACurrentMediaTime()
        var times = [Double](), intervals = [Double]()
        var previous = CACurrentMediaTime()
        for i in 0..<360 {
            let began = CACurrentMediaTime()
            intervals.append((began - previous) * 1000); previous = began
            scroll.contentView.scroll(to: .init(x: 0, y: (fullChart ? 220 : 50) + (fullChart ? 180 : 40) * sin(Double(i) / 12)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append((CACurrentMediaTime() - began) * 1000)
            try await Task.sleep(for: .seconds(max(0.001, 1.0 / 60 - (CACurrentMediaTime() - began))))
        }
        func stats(_ values: [Double]) -> [String: Double] {
            let v = values.sorted()
            return ["p50_ms": v[v.count / 2], "p95_ms": v[Int(Double(v.count) * 0.95)],
                    "max_ms": v.last!, "sum_ms": v.reduce(0, +)]
        }
        let report: [String: Any] = ["frames": times.count, "full_chart": fullChart, "window_visible": window.occlusionState.contains(.visible), "cpu_seconds": cpuSeconds() - cpuStart, "wall_seconds": CACurrentMediaTime() - wallStart, "layout_display": stats(times),
            "loop_interval": stats(Array(intervals.dropFirst())), "intervals_over_25ms": intervals.filter { $0 > 25 }.count,
            "note": "Visible isolated production components with synthetic data; scroll-loop timing is not screen-presented FPS"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}

/// Entry for the temporary AppKit host. Direct async invocation avoids blocking
/// the main actor with XCTestSuite.run while SwiftUI prepares chart data.
@MainActor
@objc(TokenBarScrollProbeEntry)
final class TokenBarScrollProbeEntry: NSObject {
    @objc static func run(_ completion: @escaping () -> Void) {
        Task { @MainActor in
            let prefix = ProcessInfo.processInfo.environment["CODEX_GUIDE_SCROLL_PERF"]!
            for index in 1...3 {
                setenv("CODEX_GUIDE_SCROLL_PERF", "\(prefix)-\(index).json", 1)
                let probe = ChartGuideScrollPerformanceTests(selector: NSSelectorFromString("testGuideDuringScroll"))
                do { try await probe.testGuideDuringScroll() }
                catch { print("Scroll probe failed: \(error)") }
            }
            completion()
        }
    }
}
