import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class BodySpeedMenuLayoutTests: XCTestCase {
    @MainActor
    func testNativeChartHeaderFitsCompactWidth() throws {
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        let host = NSHostingView(rootView: BodySpeedTrendView(monitor: monitor, compact: true).padding(18).frame(width: 420))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 290)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, 290, "Compact header must not wrap the range label vertically")
    }

    @MainActor
    func testOptInNativeMenuPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEX_BODY_SPEED_MENU_PREVIEW"],
              let path = ProcessInfo.processInfo.environment["CODEX_BODY_SPEED_AUDIT_JSON"] else {
            throw XCTSkip("Opt-in native rendering from local numeric audit")
        }
        struct Audit: Decodable { var samples: [ObservedSpeedSample]; var trend24h: [BodySpeedTrendPoint] }
        let audit = try JSONDecoder().decode(Audit.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        monitor.testSeedBodySpeedDisplay(samples: audit.samples, points: audit.trend24h, now: (audit.samples.map(\.endedAt).max() ?? 0) + 1)
        let root = VStack(alignment: .leading, spacing: 16) {
            Text("各模型最新速度 · 正文 TPS").font(.headline).foregroundStyle(.white)
            BodySpeedModelTable(monitor: monitor, dark: true)
            BodySpeedTrendView(monitor: monitor, compact: true)
        }.padding(18).frame(width: 420).background(Color(red: 0.03, green: 0.04, blue: 0.035))
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 440)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("native-speed-menu-fixed.png"))
        let rail = NSHostingView(rootView: QuotaSidebarBodySpeedReadings(monitor: monitor, onOpen: {}).frame(width: 88).padding(.vertical, 8).background(Color.black))
        rail.frame = CGRect(x: 0, y: 0, width: 88, height: 140)
        rail.layoutSubtreeIfNeeded()
        let railBitmap = try XCTUnwrap(rail.bitmapImageRepForCachingDisplay(in: rail.bounds))
        rail.cacheDisplay(in: rail.bounds, to: railBitmap)
        try XCTUnwrap(railBitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("native-speed-rail-fixed.png"))

    }
}
