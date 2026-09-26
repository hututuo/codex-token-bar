import XCTest
@testable import CodexTokenBar

final class TokenRateScaleSettingsTests: XCTestCase {
    func testDefaultRateScaleIs150() {
        XCTAssertEqual(TokenRateScaleSettings.defaultValue, 150)
        XCTAssertEqual(TokenRateScaleSettings.displayValue(TokenRateScaleSettings.defaultValue), "150/s")
        XCTAssertEqual(QuotaSidebarRatePresentation.fraction(rate: 75, fullScale: .nan, available: true), 0.5)
    }

    func testInvalidValuesAndRangeMatchCrossPlatform() {
        XCTAssertEqual(TokenRateScaleSettings.clamped(.nan), 150)
        XCTAssertEqual(TokenRateScaleSettings.clamped(.infinity), 150)
        XCTAssertEqual(TokenRateScaleSettings.clamped(900), 500)
        XCTAssertEqual(TokenRateScaleSettings.clamped(1), 50)
    }

    func testExistingCustomRateScalesStayUnchanged() {
        XCTAssertEqual(TokenRateScaleSettings.clamped(200), 200)
        XCTAssertEqual(TokenRateScaleSettings.clamped(260), 260)
    }
}
