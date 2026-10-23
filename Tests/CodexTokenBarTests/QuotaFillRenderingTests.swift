import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class QuotaFillRenderingTests: XCTestCase {
    @MainActor
    func testProductionCollapsedSevenDayOnlyQuotaPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CODEX_QUOTA_FILL_PREVIEW"] else {
            throw XCTSkip("Opt-in production collapsed quota screenshots")
        }
        for remaining in [4, 100] {
            for edge in [QuotaSidebarEdge.left, .right] {
                let suite = "QuotaFillPreview-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                var snapshot = AccountQuotaSnapshot.empty
                snapshot.sevenDay = .init(label: "7d", usedPercent: 100 - remaining,
                    resetsAt: Date().addingTimeInterval(6 * 86400))
                snapshot.status = "额度已更新"; snapshot.updatedAt = Date()
                let quota = AccountQuotaStore(quotaReader: QuotaFillReader(snapshot: snapshot),
                    userDefaults: defaults, observesUserDefaults: false)
                let controller = QuotaSidebarController(settings: defaults)
                controller.show(store: CodexUsageStore(autoStart: false, continuityDefaults: defaults),
                    monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false), quota: quota,
                    tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
                    history: QuotaHistoryStore(), edge: edge)
                defer { controller.close(); quota.stop() }
                quota.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                controller.dismiss()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                XCTAssertEqual(quota.snapshot.sevenDay?.remainingPercent, remaining)
                XCTAssertNil(quota.snapshot.fiveHour)
                let panel = try XCTUnwrap(controller.railPanel)
                XCTAssertEqual(panel.frame.width, 16)
                let view = try XCTUnwrap(panel.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: folder).appendingPathComponent("quota-\(edge.rawValue)-\(remaining).png"))
            }
        }
    }

    @MainActor
    func testSingleColorQuotaActuallyRendersAtFourPercentAndAtFullQuota() throws {
        for fraction in [0.04, 1.0] {
            let view = SmoothRateFillLayerView(frame: .init(x: 0, y: 0, width: 46, height: 4))
            view.update(fraction: fraction, minimumFraction: 0,
                colors: [Color(red: 180.0 / 255, green: 172.0 / 255, blue: 1)],
                startPoint: .leading, endPoint: .trailing, animationDuration: 0, animated: false)
            let layer = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
            let context = try XCTUnwrap(CGContext(data: nil, width: 92, height: 8, bitsPerComponent: 8,
                bytesPerRow: 92 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let coloredPixels = (0..<(92 * 8)).filter {
                data[$0 * 4 + 2] > 128 && data[$0 * 4 + 3] > 128
            }.count
            XCTAssertGreaterThan(coloredPixels, 0, "A valid single-color quota must paint pixels at \(fraction)")
            XCTAssertEqual(layer.bounds.width, 46 * fraction, accuracy: 0.5,
                           "Keep the real remaining percentage; do not inflate a small balance")
        }
    }
}

private struct QuotaFillReader: QuotaReading {
    let snapshot: AccountQuotaSnapshot
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> { .success(snapshot) }
}
