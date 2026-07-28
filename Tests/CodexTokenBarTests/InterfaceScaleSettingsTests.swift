import XCTest
import SwiftUI
@testable import CodexTokenBar

final class InterfaceScaleSettingsTests: XCTestCase {
    func testFloatingPanelScaleComposesBaseAndInterfaceScaleOnce() {
        let scale = FloatingTokenPanelScale(baseScale: 1.0, interfaceScale: 1.3)
        let layout = FloatingTokenPanelLayout(scale: scale, visibility: .default)

        XCTAssertEqual(scale.value, 1.3, accuracy: 0.001)
        XCTAssertEqual(layout.effectiveScale, 1.3, accuracy: 0.001)
        XCTAssertEqual(layout.size.width, 336, accuracy: 0.001)
        XCTAssertEqual(layout.size.height, 153, accuracy: 0.001)
        XCTAssertEqual(layout.cornerRadius, 18.2, accuracy: 0.001)
    }

    func testFloatingPanelScaleClampsComposedValueAtBothBoundaries() {
        let belowMinimum = FloatingTokenPanelScale(baseScale: 0.75, interfaceScale: 0.5)
        let aboveMaximum = FloatingTokenPanelScale(baseScale: 2.0, interfaceScale: 1.3)

        XCTAssertEqual(belowMinimum.value, 0.75, accuracy: 0.001)
        XCTAssertEqual(aboveMaximum.value, 2.0, accuracy: 0.001)
    }

    func testFloatingPanelLayoutUpdateUsesEffectiveScaleWithoutMultiplyingAgain() {
        let initial = FloatingTokenPanelLayout(
            scale: FloatingTokenPanelScale(baseScale: 1.0, interfaceScale: 1.0),
            visibility: .default
        )
        let updated = FloatingTokenPanelLayout(
            scale: FloatingTokenPanelScale(baseScale: 1.0, interfaceScale: 1.3),
            visibility: .default
        )

        XCTAssertEqual(initial.effectiveScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(updated.effectiveScale, 1.3, accuracy: 0.001)
        XCTAssertEqual(updated.size, FloatingTokenPanelMetrics.size(scale: 1.3, visibility: .default))
        XCTAssertNotEqual(initial.size, updated.size)
        XCTAssertNotEqual(initial.cornerRadius, updated.cornerRadius)
    }

    func testFloatingPanelInterfaceScaleOnePreservesBaseScale() {
        let scale = FloatingTokenPanelScale(baseScale: 1.14, interfaceScale: 1.0)
        let layout = FloatingTokenPanelLayout(scale: scale, visibility: .default)

        XCTAssertEqual(scale.value, 1.14, accuracy: 0.001)
        XCTAssertEqual(layout.size, FloatingTokenPanelMetrics.size(scale: 1.14, visibility: .default))
        XCTAssertEqual(layout.cornerRadius, FloatingTokenPanelMetrics.cornerRadius(scale: 1.14), accuracy: 0.001)
    }

    func testAutoScaleKeepsNormalLaptopScreensAtDefaultSize() {
        let scale = InterfaceScaleSettings.autoScale(logicalLongSide: 1512, pixelLongSide: 3024)
        XCTAssertEqual(scale, 1.0, accuracy: 0.001)
    }

    func testAutoScaleRaisesLargeLogicalWorkspaces() {
        XCTAssertEqual(
            InterfaceScaleSettings.autoScale(logicalLongSide: 2200, pixelLongSide: 4400),
            1.13,
            accuracy: 0.001
        )
        XCTAssertEqual(
            InterfaceScaleSettings.autoScale(logicalLongSide: 3000, pixelLongSide: 6000),
            1.24,
            accuracy: 0.001
        )
    }

    func testEffectiveScaleUsesManualWhenAutoIsDisabled() {
        let scale = InterfaceScaleSettings.effectiveScale(
            manualMultiplier: 1.10,
            autoEnabled: false,
            screen: nil
        )
        XCTAssertEqual(scale, 1.10, accuracy: 0.001)
    }

    func testEffectiveScaleIgnoresManualWhenAutoIsEnabled() {
        let automaticScale = InterfaceScaleSettings.autoScale(for: nil)
        let scale = InterfaceScaleSettings.effectiveScale(
            manualMultiplier: 1.38,
            autoEnabled: true,
            screen: nil
        )
        XCTAssertEqual(scale, automaticScale, accuracy: 0.001)
    }

    func testManualScaleAllowsUpToOneHundredThirtyEightPercent() {
        XCTAssertEqual(InterfaceScaleSettings.clampedManual(1.38), 1.38, accuracy: 0.001)
        XCTAssertEqual(InterfaceScaleSettings.clampedManual(1.80), 1.38, accuracy: 0.001)
        XCTAssertEqual(
            InterfaceScaleSettings.effectiveScale(manualMultiplier: 1.38, autoEnabled: false, screen: nil),
            1.38,
            accuracy: 0.001
        )
    }

    func testDashboardScaleProtectsNarrowWindowsFromHorizontalOverflow() {
        XCTAssertEqual(
            InterfaceScaleSettings.dashboardScale(requestedScale: 1.30, availableWidth: 1088),
            1.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            InterfaceScaleSettings.dashboardScale(requestedScale: 1.30, availableWidth: 1414.4),
            1.30,
            accuracy: 0.001
        )
    }

    @MainActor
    func testStatStripKeepsCompactHeightAtLargeManualScale() {
        let stats = DashboardStats(
            totalTokens: 4_360_000_000,
            peakDayTokens: 390_000_000,
            peakThreadTokens: 410_000_000,
            currentStreakDays: 10,
            longestStreakDays: 27,
            totalCalls: 513,
            totalThreads: 180,
            mostUsedReasoning: "medium",
            skillsExplored: 0,
            totalSkillsUsed: 0
        )
        let snapshot = DashboardSnapshot(
            stats: stats,
            dailyUsage: [],
            recentBins: [],
            hourlyUsage: [],
            pluginUsage: [],
            cacheUsage: .empty,
            generatedAt: Date(timeIntervalSince1970: 1_800)
        )

        let content = InterfaceScaledContainer(scale: 1.30, visualWidth: 980 * 1.30) {
            StatStrip(snapshot: snapshot)
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 980 * 1.30, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        let fittingHeight = hostingView.fittingSize.height
        XCTAssertLessThanOrEqual(fittingHeight, 96, "Stat strip should not expand into a giant row at 130% scale.")
        XCTAssertGreaterThanOrEqual(fittingHeight, 70, "Stat strip should keep its normal readable height.")
    }
}
