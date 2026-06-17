import XCTest
@testable import CodexTokenBar

final class InterfaceScaleSettingsTests: XCTestCase {
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

    func testEffectiveScaleCombinesManualAndAutoWhenEnabled() {
        let scale = InterfaceScaleSettings.effectiveScale(
            manualMultiplier: 1.10,
            autoEnabled: false,
            screen: nil
        )
        XCTAssertEqual(scale, 1.10, accuracy: 0.001)
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
}
