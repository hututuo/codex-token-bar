import XCTest
@testable import CodexTokenBar

final class TokenRateScaleSettingsTests: XCTestCase {
    func testV092InitializationOverridesOldSavedScaleOnlyOnce() throws {
        let suite = "rate-scale-v092-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(230.0, forKey: TokenRateScaleSettings.key)

        TokenRateScaleSettings.initializeForV092(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: TokenRateScaleSettings.key), 150.0)
        XCTAssertTrue(defaults.bool(forKey: TokenRateScaleSettings.initializationKey))

        defaults.set(260.0, forKey: TokenRateScaleSettings.key)
        TokenRateScaleSettings.initializeForV092(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: TokenRateScaleSettings.key), 260.0)
    }

    func testV092InitializationAlsoWritesFreshInstallDefault() throws {
        let suite = "rate-scale-v092-fresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        TokenRateScaleSettings.initializeForV092(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: TokenRateScaleSettings.key), 150.0)
    }
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
