import XCTest
@testable import CodexTokenBar

final class AccountQuotaRefreshCadenceTests: XCTestCase {
    func testAllowedRefreshCadencesAreFixedAndOrdered() {
        XCTAssertEqual(AccountQuotaRefreshCadence.allCases.map(\.seconds), [30, 60, 180, 300, 600])
        XCTAssertEqual(AccountQuotaRefreshCadence.allCases.map(\.label), ["30 秒", "1 分钟", "3 分钟", "5 分钟", "10 分钟"])
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
        XCTAssertEqual(AccountQuotaRefreshCadence.threeMinutes.label, "3 分钟")
        XCTAssertEqual(AccountQuotaRefreshCadence.fiveMinutes.label, "5 分钟")
        XCTAssertEqual(AccountQuotaRefreshCadence.tenMinutes.label, "10 分钟")
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
