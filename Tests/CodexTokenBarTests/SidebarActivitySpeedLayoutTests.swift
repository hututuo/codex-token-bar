import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SidebarActivitySpeedLayoutTests: XCTestCase {
    @MainActor func testCompactCurveKeepsContentInsideTheMedianCardInsets() throws {
        let history = ActivitySpeedHistoryController()
        history.start()
        let now = Date().timeIntervalSince1970
        let clients: Set<String> = ["codex", "claudeDesktop"]
        for client in clients {
            for i in 0..<180 {
                history.record(client: client, sourceIdentity: "layout-fixture", rates: [
                    .init(model: "gpt-6.1-sol", tokensPerSecond: 20 + Double(i % 60))
                ], at: now - 180 + Double(i), available: true,
                   mode: client == "codex" ? .bar : .agentSpeed)
            }
        }
        let suite = "SidebarActivitySpeedLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bar", forKey: ActivitySpeedDisplayMode.key)
        defaults.set(ActivityRateUnit.tokens.rawValue, forKey: ActivityRateUnit.preferenceKey)
        let view = ActivitySpeedSummaryView(allowed: clients, compact: true, onOpen: {}, history: history)
            .defaultAppStorage(defaults).frame(width: 88).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertLessThanOrEqual(size.width, 88)
        XCTAssertLessThanOrEqual(size.height, 100)
        XCTAssertGreaterThan(size.height, 60, "Fixture must actually render the curve")
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let edge = max(1, Int(4 * CGFloat(bitmap.pixelsWide) / size.width))
        // A fittingSize assertion alone also passed for the broken version:
        // its label was wider than its parent and was cut off at x=0. Verify
        // actual painted pixels leave a quiet margin on both sides.
        for x in Array(0..<edge) + Array((bitmap.pixelsWide - edge)..<bitmap.pixelsWide) {
            for y in 0..<bitmap.pixelsHigh {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.05,
                                  "Paint escaped the sidebar inset at \(x),\(y)")
            }
        }
        if let folder = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("native-sidebar-speed-insets.png"))
        }
    }
}
