import XCTest
@testable import CodexTokenBar

final class DisplayModeMigrationTests: XCTestCase {
    func testStartupRepairDefaultsUnsetOrOffModeToFloatingOnFirstLaunch() {
        let defaults = makeDefaults()
        defaults.set(TokenDisplayMode.off.rawValue, forKey: "tokenDisplayMode")

        DisplayModeMigration.repairStartup(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "tokenDisplayMode"), TokenDisplayMode.floating.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "tokenDisplayModeInitialDefaultAppliedV03"))
    }

    func testViewDefaultsMigratesLegacyStatusBarModeToSeparateSurfaceFlags() {
        let defaults = makeDefaults()
        defaults.set(TokenDisplayMode.statusBar.rawValue, forKey: "tokenDisplayMode")
        var floatingEnabled = true
        var statusBarEnabled = false
        defaults.set(true, forKey: "tokenDisplayModeInitialDefaultAppliedV03")
        defaults.set(true, forKey: "tokenDisplayModeUserSelected")
        defaults.set(true, forKey: "tokenDisplayModePanelCloseRepairV01")

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertFalse(floatingEnabled)
        XCTAssertTrue(statusBarEnabled)
        XCTAssertTrue(defaults.bool(forKey: "displaySurfacePairMigrationV01"))
        XCTAssertTrue(defaults.bool(forKey: "tokenDisplayModeDefaultedToFloatingV021"))
        XCTAssertTrue(defaults.bool(forKey: "tokenDisplayModeDefaultedToFloatingQuotaV01"))
        XCTAssertTrue(defaults.bool(forKey: "tokenDisplayModeDefaultedToFloatingQuotaV02"))
    }

    func testViewDefaultsDoesNotOverrideSeparateSurfaceFlagsAfterMigration() {
        let defaults = makeDefaults()
        defaults.set(TokenDisplayMode.statusBar.rawValue, forKey: "tokenDisplayMode")
        defaults.set(true, forKey: "displaySurfacePairMigrationV01")
        defaults.set(true, forKey: "statusBarMetricsMigrationV01")
        var floatingEnabled = true
        var statusBarEnabled = false

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertTrue(floatingEnabled)
        XCTAssertFalse(statusBarEnabled)
    }

    func testViewDefaultsSeedsMissingStatusBarConfigurationWithoutChangingCurrentFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "displaySurfacePairMigrationV01")
        var floatingEnabled = true
        var statusBarEnabled = true

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertTrue(statusBarEnabled)
        XCTAssertTrue(defaults.bool(forKey: "statusBarPanelEnabled"))
        XCTAssertEqual(
            defaults.integer(forKey: StatusBarMetricConfiguration.versionKey),
            StatusBarMetricConfiguration.currentVersion
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.orderKey),
            StatusBarMetricConfiguration.defaultOrderRaw
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.selectionKey),
            StatusBarMetricConfiguration.defaultSelectionRaw
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.labelStyleKey),
            StatusBarMetricConfiguration.defaultLabelStyle.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusSummaryConfiguration.orderKey),
            StatusSummaryConfiguration.defaultOrderRaw
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusSummaryConfiguration.selectionKey),
            StatusSummaryConfiguration.defaultSelectionRaw
        )

    }

    func testViewDefaultsPreservesExistingDisabledFlagAndCustomStatusBarConfiguration() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "displaySurfacePairMigrationV01")
        defaults.set(false, forKey: "statusBarPanelEnabled")
        defaults.set("unread,rate", forKey: StatusBarMetricConfiguration.orderKey)
        defaults.set("unread", forKey: StatusBarMetricConfiguration.selectionKey)
        defaults.set(false, forKey: StatusBarMetricConfiguration.showsIconKey)
        defaults.set("hidden", forKey: StatusBarMetricConfiguration.labelStyleKey)
        defaults.set("radar,overview", forKey: StatusSummaryConfiguration.orderKey)
        defaults.set("radar", forKey: StatusSummaryConfiguration.selectionKey)
        var floatingEnabled = true
        var statusBarEnabled = false

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertFalse(statusBarEnabled)
        XCTAssertFalse(defaults.bool(forKey: "statusBarPanelEnabled"))
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.orderKey),
            "unread,rate"
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.selectionKey),
            "unread"
        )
        XCTAssertFalse(defaults.bool(forKey: StatusBarMetricConfiguration.showsIconKey))
        XCTAssertEqual(
            defaults.string(forKey: StatusBarMetricConfiguration.labelStyleKey),
            "hidden"
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusSummaryConfiguration.orderKey),
            "radar,overview"
        )
        XCTAssertEqual(
            defaults.string(forKey: StatusSummaryConfiguration.selectionKey),
            "radar"
        )
    }

    func testViewDefaultsMigratesLegacyFloatingPanelColorsToCurrentDefault() {
        let defaults = makeDefaults()
        defaults.set("#E6F4FF", forKey: "floatingPanelGradientStartHex")
        defaults.set("#D4E8FF", forKey: "floatingPanelGradientEndHex")
        defaults.set(true, forKey: "displaySurfacePairMigrationV01")
        var floatingEnabled = true
        var statusBarEnabled = false

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: "floatingPanelGradientStartHex"), "#FAF9FF")
        XCTAssertEqual(defaults.string(forKey: "floatingPanelGradientEndHex"), "#00C2EF")
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelColorDefaultMigrationV01"))
    }

    func testViewDefaultsKeepsUserCustomizedFloatingPanelColors() {
        let defaults = makeDefaults()
        defaults.set("#111111", forKey: "floatingPanelGradientStartHex")
        defaults.set("#222222", forKey: "floatingPanelGradientEndHex")
        var floatingEnabled = true
        var statusBarEnabled = false

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: "floatingPanelGradientStartHex"), "#111111")
        XCTAssertEqual(defaults.string(forKey: "floatingPanelGradientEndHex"), "#222222")
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelColorDefaultMigrationV01"))
    }

    func testViewDefaultsShowsAllFloatingPanelContentAfterUpgrade() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "floatingPanelShowRateAndBar")
        defaults.set(false, forKey: "floatingPanelShowUsageStatus")
        defaults.set(false, forKey: "floatingPanelShowMetrics")
        defaults.set(false, forKey: "floatingPanelShowRunningThreads")
        defaults.set(false, forKey: "floatingPanelShowQuota")
        defaults.set(false, forKey: "floatingPanelShowRadar")
        defaults.set("radar,metrics", forKey: "floatingPanelContentOrderV01")
        defaults.set(true, forKey: "displaySurfacePairMigrationV01")
        defaults.set(true, forKey: "floatingPanelContentDefaultsMigrationV01")
        var floatingEnabled = true
        var statusBarEnabled = false

        DisplayModeMigration.applyViewDefaults(
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            defaults: defaults
        )

        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowRateAndBar"))
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowUsageStatus"))
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowMetrics"))
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowRunningThreads"))
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowQuota"))
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelShowRadar"))
        XCTAssertEqual(defaults.string(forKey: "floatingPanelContentOrderV01"), FloatingPanelContentVisibility.defaultOrderRaw)
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelContentDefaultsMigrationV02"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexTokenBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
