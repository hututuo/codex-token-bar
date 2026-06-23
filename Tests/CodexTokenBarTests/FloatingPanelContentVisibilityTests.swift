import XCTest
@testable import CodexTokenBar

final class FloatingPanelContentVisibilityTests: XCTestCase {
    func testDefaultVisibilityShowsAllFloatingPanelGroups() {
        let visibility = FloatingPanelContentVisibility.default

        XCTAssertEqual(visibility.visibleGroups, FloatingPanelContentGroup.allCases)
        XCTAssertTrue(visibility.shows(.rateAndBar))
        XCTAssertTrue(visibility.shows(.usageStatus))
        XCTAssertTrue(visibility.shows(.metrics))
        XCTAssertTrue(visibility.shows(.quota))
        XCTAssertTrue(visibility.shows(.radar))
    }

    func testAdaptiveSizeShrinksWhenOnlyUsageStatusIsVisible() {
        let fullSize = FloatingTokenPanelMetrics.size(scale: 1, visibility: .default)
        let statusOnlySize = FloatingTokenPanelMetrics.size(
            scale: 1,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: true,
                showMetrics: false,
                showQuota: false,
                showRadar: false
            )
        )

        XCTAssertLessThan(statusOnlySize.width, fullSize.width)
        XCTAssertLessThan(statusOnlySize.height, fullSize.height)
    }

    func testUsageStatusEmbedsIntoRateRowWhenRateIsVisible() {
        let height = FloatingTokenPanelMetrics.contentHeight(visibility: .default)
        let expectedHeight = FloatingTokenPanelMetrics.rateRowHeight
            + FloatingTokenPanelMetrics.metricRowHeight
            + FloatingTokenPanelMetrics.quotaRowHeight
            + FloatingTokenPanelMetrics.radarRowHeight
            + FloatingTokenPanelMetrics.rowSpacing * 3

        XCTAssertEqual(height, expectedHeight, accuracy: 0.001)
    }

    func testUsageStatusUsesStandaloneRowOnlyWhenRateIsHidden() {
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )

        XCTAssertEqual(
            FloatingTokenPanelMetrics.contentHeight(visibility: visibility),
            FloatingTokenPanelMetrics.usageStatusRowHeight,
            accuracy: 0.001
        )
    }

    func testAdaptiveSizeKeepsControlsReachableWhenAllGroupsAreHidden() {
        let hiddenSize = FloatingTokenPanelMetrics.size(
            scale: 1,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: false,
                showRadar: false
            )
        )

        XCTAssertGreaterThanOrEqual(hiddenSize.width, FloatingTokenPanelMetrics.minimumControlSize.width)
        XCTAssertGreaterThanOrEqual(hiddenSize.height, FloatingTokenPanelMetrics.minimumControlSize.height)
        XCTAssertLessThan(hiddenSize.width, FloatingTokenPanelMetrics.size(scale: 1, visibility: .default).width)
    }

    func testTopSafetyInsetOnlyAppearsWhenUsageStatusIsHidden() {
        let rateOnlyWithoutUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: false,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let statusOnlyWithUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let radarOnlyWithoutUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: false,
            showQuota: false,
            showRadar: true
        )
        let rateOnlyHeight = FloatingTokenPanelMetrics.verticalPadding * 2
            + FloatingTokenPanelMetrics.singleElementTopInset
            + FloatingTokenPanelMetrics.rateRowHeight
        let statusOnlyHeight = max(
            FloatingTokenPanelMetrics.minimumControlSize.height,
            FloatingTokenPanelMetrics.verticalPadding * 2 + FloatingTokenPanelMetrics.usageStatusRowHeight
        )
        let radarOnlyHeight = FloatingTokenPanelMetrics.verticalPadding * 2
            + FloatingTokenPanelMetrics.singleElementTopInset
            + FloatingTokenPanelMetrics.radarRowHeight

        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: rateOnlyWithoutUsageStatus).height, rateOnlyHeight, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: statusOnlyWithUsageStatus).height, statusOnlyHeight, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: radarOnlyWithoutUsageStatus).height, radarOnlyHeight, accuracy: 0.001)
        XCTAssertTrue(rateOnlyWithoutUsageStatus.needsTopControlInset)
        XCTAssertFalse(statusOnlyWithUsageStatus.needsTopControlInset)
        XCTAssertTrue(radarOnlyWithoutUsageStatus.needsTopControlInset)
    }

    func testFloatingPanelSettingsExposeFiveContentToggles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelAppearanceSettingsView.swift")
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let settingsSource = try String(contentsOf: settingsView, encoding: .utf8)
        let dashboardSource = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(settingsSource.contains("FloatingPanelContentSettings("))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.rateAndBarKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.usageStatusKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.metricsKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.quotaKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.radarKey)"))
        XCTAssertTrue(dashboardSource.contains("@AppStorage(FloatingPanelContentVisibility.rateAndBarKey)"))
        XCTAssertTrue(dashboardSource.contains("visibility: floatingPanelContentVisibility"))
    }

    func testFloatingPanelPassesRadarSnapshotIntoRadarRow() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboard = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let floatingPanel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift")
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")

        let dashboardSource = try String(contentsOf: dashboard, encoding: .utf8)
        let floatingPanelSource = try String(contentsOf: floatingPanel, encoding: .utf8)
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
        let componentsSource = try String(contentsOf: components, encoding: .utf8)

        XCTAssertTrue(dashboardSource.contains("radar: radarStore"))
        XCTAssertTrue(floatingPanelSource.contains("@ObservedObject var radar: CodexRadarStore"))
        XCTAssertTrue(floatingPanelSource.contains("radarSnapshot: radar.snapshot"))
        XCTAssertTrue(surfaceSource.contains("if visibility.showRadar"))
        XCTAssertTrue(surfaceSource.contains("TokenDisplayRadarStrip(snapshot: radarSnapshot)"))
        XCTAssertTrue(componentsSource.contains("struct TokenDisplayRadarStrip"))
        XCTAssertTrue(componentsSource.contains("动作 \\(snapshot?.recommendedAction"))
        XCTAssertTrue(componentsSource.contains("24h \\(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability24hPercent))  48h \\(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability48hPercent))"))
        XCTAssertTrue(componentsSource.contains("alignment: .leading, spacing: 2.scaled(by: displayScale)"))
        XCTAssertTrue(componentsSource.contains("alignment: .trailing, spacing: 1.scaled(by: displayScale)"))
        XCTAssertTrue(componentsSource.contains("latest?.scoreDisplayText"))
        XCTAssertTrue(componentsSource.contains("tokenDisplayRadarIQText(snapshot, effort: \"high\")"))
        XCTAssertTrue(componentsSource.contains("tokenDisplayRadarIQText(snapshot, effort: \"xhigh\")"))

        let radarStrip = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayRadarStrip",
            in: componentsSource,
            endingBefore: "private func tokenDisplayRadarProbabilityText"
        ))
        XCTAssertTrue(radarStrip.contains("Text(\"动作 \\(snapshot?.recommendedAction ?? \"--\")\")"))
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(Color.black.opacity(0.88))"))
        XCTAssertTrue(radarStrip.contains("Text(latest?.scoreDisplayText ?? \"IQ --\")"))
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(Color.black.opacity(0.9))"))
    }

    func testUsageStatusRendersOnRateBarAndStandaloneTextHasNoBackground() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
        let componentsSource = try String(contentsOf: components, encoding: .utf8)

        XCTAssertTrue(surfaceSource.contains("usageStatus: visibility.embedsUsageStatusInRateRow ? snapshot.compactUsageStatus : nil"))
        XCTAssertTrue(surfaceSource.contains("if visibility.showsStandaloneUsageStatus"))
        XCTAssertTrue(componentsSource.contains("let usageStatus: String?"))

        let standaloneLine = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayUsageStatusLine",
            in: componentsSource,
            endingBefore: "struct TokenDisplayRateBar"
        ))
        XCTAssertFalse(standaloneLine.contains(".background("))
        XCTAssertFalse(standaloneLine.contains("Capsule()"))
    }

    func testStandaloneUsageStatusIsBlackButRateBarStatusStaysWhite() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let standaloneLine = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayUsageStatusLine",
            in: componentsSource,
            endingBefore: "struct TokenDisplayRateBar"
        ))
        let rateBar = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayRateBar",
            in: componentsSource,
            endingBefore: "struct TokenDisplayMetric"
        ))

        XCTAssertTrue(rateBar.contains("let barCenterY = 22.scaled(by: displayScale)"))
        XCTAssertFalse(rateBar.contains("usageStatus == nil ? height / 2"))
        XCTAssertTrue(standaloneLine.contains("size: 13.6.scaled(by: displayScale)"))
        XCTAssertTrue(standaloneLine.contains("Color.black.opacity(0.88)"))
        XCTAssertTrue(rateBar.contains("Color.white.opacity(0.88)"))
    }

    private func sourceBlock(named name: String, in source: String, endingBefore marker: String) -> String? {
        guard let start = source.range(of: "struct \(name)")?.lowerBound,
              let end = source[start...].range(of: marker)?.lowerBound
        else {
            return nil
        }
        return String(source[start..<end])
    }
}
