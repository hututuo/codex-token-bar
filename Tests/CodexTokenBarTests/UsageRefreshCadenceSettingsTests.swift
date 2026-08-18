import Foundation
import XCTest
@testable import CodexTokenBar

final class UsageRefreshCadenceSettingsTests: XCTestCase {
    func testMissingValuesUseIndependentDefaults() {
        let defaults = makeDefaults()

        let settings = UsageRefreshCadenceSettings.load(defaults: defaults)

        XCTAssertEqual(settings.usageLightRefreshIntervalSeconds, 150)
        XCTAssertEqual(settings.usageVisibleAggregateIntervalMinutes, 5)
        XCTAssertEqual(settings.usageBackgroundAggregateIntervalMinutes, 30)
    }

    func testInvalidValuesFallBackWithoutChangingQuotaRefreshSetting() {
        let defaults = makeDefaults()
        defaults.set("not-a-duration", forKey: UsageRefreshCadenceSettings.lightRefreshIntervalStorageKey)
        defaults.set(7, forKey: UsageRefreshCadenceSettings.visibleAggregateIntervalStorageKey)
        defaults.set(15.5, forKey: UsageRefreshCadenceSettings.backgroundAggregateIntervalStorageKey)
        defaults.set(AccountQuotaRefreshCadence.thirtySeconds.rawValue, forKey: AccountQuotaRefreshCadence.storageKey)

        let settings = UsageRefreshCadenceSettings.load(defaults: defaults)

        XCTAssertEqual(settings.usageLightRefreshIntervalSeconds, 150)
        XCTAssertEqual(settings.usageVisibleAggregateIntervalMinutes, 5)
        XCTAssertEqual(settings.usageBackgroundAggregateIntervalMinutes, 30)
        XCTAssertEqual(
            defaults.string(forKey: AccountQuotaRefreshCadence.storageKey),
            AccountQuotaRefreshCadence.thirtySeconds.rawValue
        )
    }

    func testValidValuesRoundTripFromUserDefaults() {
        let defaults = makeDefaults()
        defaults.set(600, forKey: UsageRefreshCadenceSettings.lightRefreshIntervalStorageKey)
        defaults.set("10", forKey: UsageRefreshCadenceSettings.visibleAggregateIntervalStorageKey)
        defaults.set(15, forKey: UsageRefreshCadenceSettings.backgroundAggregateIntervalStorageKey)

        let settings = UsageRefreshCadenceSettings.load(defaults: defaults)

        XCTAssertEqual(
            settings,
            UsageRefreshCadenceSettings(
                usageLightRefreshIntervalSeconds: 600,
                usageVisibleAggregateIntervalMinutes: 10,
                usageBackgroundAggregateIntervalMinutes: 15
            )
        )
    }

    func testInitializerUsesThePerSettingDefaultForInvalidValues() {
        let settings = UsageRefreshCadenceSettings(
            usageLightRefreshIntervalSeconds: 61,
            usageVisibleAggregateIntervalMinutes: 11,
            usageBackgroundAggregateIntervalMinutes: 16
        )

        XCTAssertEqual(settings.usageLightRefreshIntervalSeconds, 150)
        XCTAssertEqual(settings.usageVisibleAggregateIntervalMinutes, 5)
        XCTAssertEqual(settings.usageBackgroundAggregateIntervalMinutes, 30)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UsageRefreshCadenceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class UsageRefreshCadencePolicyTests: XCTestCase {
    func testLatestEligibleBoundaryWaitsForTheSettleDelay() {
        let boundary = Date(timeIntervalSince1970: 15 * 60)

        XCTAssertEqual(
            UsageRefreshCadencePolicy.latestEligibleBoundary(
                now: boundary.addingTimeInterval(UsageRefreshCadencePolicy.settleDelay - 0.001)
            ).timeIntervalSince1970,
            boundary.addingTimeInterval(-UsageRefreshCadencePolicy.fiveMinuteBoundary).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UsageRefreshCadencePolicy.latestEligibleBoundary(
                now: boundary.addingTimeInterval(UsageRefreshCadencePolicy.settleDelay)
            ).timeIntervalSince1970,
            boundary.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testNextAggregateFireDateUsesWallClockBoundaryAndSettleDelay() {
        let after = Date(timeIntervalSince1970: 4 * 60 + 50)

        for minutes in UsageRefreshCadenceSettings.aggregateIntervalOptions {
            let fireDate = UsageRefreshCadencePolicy.nextAggregateFireDate(
                after: after,
                intervalMinutes: minutes
            )
            let expected = Date(timeIntervalSince1970: TimeInterval(minutes * 60 + 15))
            XCTAssertEqual(
                fireDate.timeIntervalSince1970,
                expected.timeIntervalSince1970,
                accuracy: 0.001,
                "interval = \(minutes)"
            )
        }
    }

    func testNextAggregateFireDateNeverRefiresCurrentBoundary() {
        let atSettledBoundary = Date(timeIntervalSince1970: 5 * 60 + 15)

        XCTAssertEqual(
            UsageRefreshCadencePolicy.nextAggregateFireDate(
                after: atSettledBoundary,
                intervalMinutes: 5
            ).timeIntervalSince1970,
            Date(timeIntervalSince1970: 10 * 60 + 15).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testAggregateIntervalSelectsVisibleOrBackgroundSetting() {
        let settings = UsageRefreshCadenceSettings(
            usageLightRefreshIntervalSeconds: 60,
            usageVisibleAggregateIntervalMinutes: 15,
            usageBackgroundAggregateIntervalMinutes: 30
        )

        XCTAssertEqual(
            UsageRefreshCadencePolicy.aggregateInterval(
                mainDashboardVisible: true,
                settings: settings
            ),
            15 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UsageRefreshCadencePolicy.aggregateInterval(
                mainDashboardVisible: false,
                settings: settings
            ),
            30 * 60,
            accuracy: 0.001
        )
    }

    func testLegacyDecisionDoesNotUseLiveActivityAcceleration() {
        var snapshot = LiveRateSnapshot()
        snapshot.rollingTokensPerSecond = 100
        snapshot.updatedAt = Date()

        let decision = UsageRefreshCadencePolicy.decision(
            snapshot: snapshot,
            onlyCompactSurfaceVisible: false,
            now: snapshot.updatedAt
        )

        XCTAssertFalse(decision.isActive)
        XCTAssertNil(decision.recoveryDelay)
        XCTAssertEqual(decision.interval, 5 * 60, accuracy: 0.001)
    }
}
