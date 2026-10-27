import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardClientQuotaLayoutTests: XCTestCase {
    @MainActor func testAggregateAndClaudeOnlyRenderWithoutDroppingOrSqueezingQuotaWindows() throws {
        let suite = "DashboardClientQuotaLayout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let snapshot = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 28, resetsAt: now.addingTimeInterval(259200)),
            planType: "pro", resetCreditsAvailableCount: 3, status: "额度已读取")
        let items = ClientQuotaProjection.previewItems(includeClaude: true, now: now)
        func render(_ name: String, _ quotas: [ClientQuotaItem]) throws -> NSSize {
            let root = AccountQuotaStrip(snapshot: snapshot, showingResetCreditDetails: .constant(false), clientItems: quotas)
                .frame(width: 980).background(AppTheme.pageBackground)
                .environment(\.colorScheme, .dark).defaultAppStorage(defaults)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(x: 0, y: 0, width: 980, height: 180)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(size.width, 980, accuracy: 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let folder = ProcessInfo.processInfo.environment["TOKENBAR_DASHBOARD_QUOTA_RENDER_DIR"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
            return size
        }
        let aggregate = try render("aggregate-native", items)
        XCTAssertLessThan(aggregate.height, 190, "Three windows plus account tools should stay compact")
        let claude = try render("claude-only-native", items.filter { $0.client == "claudeCode" })
        XCTAssertLessThan(claude.height, aggregate.height - 30, "Claude-only must not mount Codex account tools")
        var many = items
        for index in 0..<5 {
            many.append(ClientQuotaItem(id: "codex:extra-\(index)", client: "codex", window: "窗口 \(index + 1)",
                remaining: Double(index * 20), resetsAt: now, source: "模拟额度", status: ""))
        }
        let wrapped = try render("many-windows-native", many)
        XCTAssertGreaterThan(wrapped.height, aggregate.height + 20, "Extra windows must wrap, never be dropped")
        XCTAssertLessThan(wrapped.height, 330)
    }
}
