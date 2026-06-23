import XCTest

final class CodexRadarViewPlacementTests: XCTestCase {
    func testDashboardPlacesRadarStripAboveLiveRateView() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        let radarRange = try XCTUnwrap(source.range(of: "CodexRadarStrip("))
        let liveRateRange = try XCTUnwrap(source.range(of: "LiveRateView("))

        XCTAssertLessThan(radarRange.lowerBound, liveRateRange.lowerBound)
        XCTAssertTrue(source.contains("@StateObject private var radarStore = CodexRadarStore()"))
        XCTAssertTrue(source.contains("showingCodexRadarDetails"))
    }

    func testRadarStoreDefaultsToTenMinuteRefresh() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeFile = projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexRadarStore.swift")
        let source = try String(contentsOf: storeFile, encoding: .utf8)

        XCTAssertTrue(source.contains("refreshInterval: TimeInterval = 600"))
    }
}
