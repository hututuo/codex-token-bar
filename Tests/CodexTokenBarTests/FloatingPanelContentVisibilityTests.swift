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

    func testFloatingPanelReadableTextPaletteKeepsGrayBandNarrow() {
        let lightAppearance = FloatingPanelAppearance(
            startHex: "#FFFFFF",
            endHex: "#E6F4FF",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let darkAppearance = FloatingPanelAppearance(
            startHex: "#07111F",
            endHex: "#111827",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let grayBandAppearance = FloatingPanelAppearance(
            startHex: "#999999",
            endHex: "#999999",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let outerBandAppearance = FloatingPanelAppearance(
            startHex: "#777777",
            endHex: "#777777",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )

        let lightPalette = lightAppearance.readableTextPalette
        let darkPalette = darkAppearance.readableTextPalette
        let grayBandPalette = grayBandAppearance.readableTextPalette
        let outerBandPalette = outerBandAppearance.readableTextPalette

        XCTAssertLessThan(lightPalette.primaryWhite, 0.18)
        XCTAssertGreaterThan(lightPalette.secondaryWhite, lightPalette.primaryWhite)
        XCTAssertGreaterThan(grayBandPalette.primaryWhite, 0.42)
        XCTAssertLessThan(grayBandPalette.primaryWhite, 0.68)
        XCTAssertGreaterThan(outerBandPalette.primaryWhite, 0.84)
        XCTAssertLessThan(outerBandPalette.secondaryWhite, outerBandPalette.primaryWhite)
        XCTAssertGreaterThan(darkPalette.primaryWhite, 0.82)
        XCTAssertLessThan(darkPalette.secondaryWhite, darkPalette.primaryWhite)
        XCTAssertGreaterThan(outerBandPalette.primaryWhite - grayBandPalette.primaryWhite, 0.18)
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

    func testFloatingPanelPaletteMenuDoesNotAutoDismissWhileEditing() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paletteMenu = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelPaletteMenu.swift")
        let paletteSource = try String(contentsOf: paletteMenu, encoding: .utf8)

        XCTAssertFalse(paletteSource.contains(".onChange(of: startHex)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: endHex)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: directionRaw)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: styleRaw)"))
        XCTAssertFalse(paletteSource.contains("schedulePaletteClose"))
        XCTAssertFalse(paletteSource.contains("closePaletteSoon"))
        XCTAssertTrue(paletteSource.contains("closeAction: closePaletteNow"))
    }

    func testFloatingPanelPaletteMenuKeepsDraftColorsDuringPickerDrag() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paletteMenu = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelPaletteMenu.swift")
        let paletteSource = try String(contentsOf: paletteMenu, encoding: .utf8)

        XCTAssertTrue(paletteSource.contains("@State private var startColorDraft"))
        XCTAssertTrue(paletteSource.contains("@State private var endColorDraft"))
        XCTAssertTrue(paletteSource.contains("ColorPicker(\"\", selection: draftColorBinding($startColorDraft, hex: $startHex)"))
        XCTAssertTrue(paletteSource.contains("ColorPicker(\"\", selection: draftColorBinding($endColorDraft, hex: $endHex)"))
        XCTAssertFalse(paletteSource.contains("ColorPicker(\"\", selection: colorBinding($startHex)"))
        XCTAssertFalse(paletteSource.contains("ColorPicker(\"\", selection: colorBinding($endHex)"))
        XCTAssertTrue(paletteSource.contains("draftColor.wrappedValue = newValue"))
        XCTAssertTrue(paletteSource.contains("hex.wrappedValue = nextHex"))
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
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertTrue(radarStrip.contains("Text(latest?.scoreDisplayText ?? \"IQ --\")"))
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(textPalette.primaryColor)"))
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

    func testFloatingPanelTextUsesReadableToneExceptQuotaSegments() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let floatingPanel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift")
        let controls = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelControls.swift")
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let floatingPanelSource = try String(contentsOf: floatingPanel, encoding: .utf8)
        let controlsSource = try String(contentsOf: controls, encoding: .utf8)
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
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
        let metric = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayMetric",
            in: componentsSource,
            endingBefore: "struct TokenGlassBackground"
        ))
        let quotaSegment = try XCTUnwrap(sourceBlock(
            named: "TokenQuotaMiniSegment",
            in: componentsSource,
            endingBefore: "struct TokenDisplayUsageStatusLine"
        ))

        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayTextPalette, appearance.readableTextPalette)"))
        XCTAssertTrue(controlsSource.contains("@Environment(\\.tokenDisplayTextPalette) private var textPalette"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayTextPalette) private var textPalette"))
        XCTAssertTrue(rateBar.contains("let barCenterY = 22.scaled(by: displayScale)"))
        XCTAssertFalse(rateBar.contains("usageStatus == nil ? height / 2"))
        XCTAssertTrue(standaloneLine.contains("size: 13.6.scaled(by: displayScale)"))
        XCTAssertTrue(standaloneLine.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertTrue(rateBar.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertTrue(metric.contains(".foregroundStyle(textPalette.secondaryColor)"))
        XCTAssertTrue(metric.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertFalse(quotaSegment.contains("tokenDisplayTextPalette"))
        XCTAssertTrue(quotaSegment.contains(".foregroundStyle(.primary.opacity(0.82))"))
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
