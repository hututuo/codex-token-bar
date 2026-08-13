import XCTest
@testable import CodexTokenBar

final class AccountQuotaRefreshCadenceTests: XCTestCase {
    func testAllowedRefreshCadencesAreFixedAndOrdered() {
        XCTAssertEqual(AccountQuotaRefreshCadence.allCases.map(\.seconds), [30, 60])
        XCTAssertEqual(AccountQuotaRefreshCadence.allCases.map(\.label), ["30 秒", "1 分钟"])
    }

    func testDefaultRefreshCadenceIsOneMinute() {
        XCTAssertEqual(AccountQuotaRefreshCadence.defaultValue.seconds, 60)
        XCTAssertEqual(AccountQuotaRefreshCadence.defaultRawValue, "60")
    }

    func testInvalidRefreshCadenceFallsBackToOneMinute() {
        XCTAssertEqual(AccountQuotaRefreshCadence.value(for: "bogus"), .defaultValue)
        XCTAssertEqual(AccountQuotaRefreshCadence.value(for: "999").seconds, 60)
    }

    func testDisplayLabelsAreChineseAndCompact() {
        XCTAssertEqual(AccountQuotaRefreshCadence.thirtySeconds.label, "30 秒")
        XCTAssertEqual(AccountQuotaRefreshCadence.oneMinute.label, "1 分钟")
    }

    func testLegacyCadencesAreSanitizedToOneMinute() {
        for rawValue in ["180", "300", "600"] {
            XCTAssertEqual(AccountQuotaRefreshCadence.value(for: rawValue), .oneMinute)
        }
    }

    func testThirtySecondCadenceIsNotSwallowedByFixedThirtySecondCooldown() {
        XCTAssertFalse(
            AccountQuotaAutomaticRefreshPolicy.shouldSkipAutomaticRefresh(
                snapshotIsAvailable: true,
                recentSuccessAge: 29.8,
                automaticRefreshInterval: 30
            )
        )
    }

    func testDefaultOneMinuteCadenceKeepsThirtySecondCooldown() {
        XCTAssertTrue(
            AccountQuotaAutomaticRefreshPolicy.shouldSkipAutomaticRefresh(
                snapshotIsAvailable: true,
                recentSuccessAge: 29.8,
                automaticRefreshInterval: 60
            )
        )
        XCTAssertFalse(
            AccountQuotaAutomaticRefreshPolicy.shouldSkipAutomaticRefresh(
                snapshotIsAvailable: true,
                recentSuccessAge: 30.1,
                automaticRefreshInterval: 60
            )
        )
    }
}
