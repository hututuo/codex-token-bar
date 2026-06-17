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
        var mode = TokenDisplayMode.statusBar.rawValue
        var floatingEnabled = true
        var statusBarEnabled = false
        var pairMigrationApplied = false
        var defaultedToFloating = false
        var defaultedToFloatingQuota = false
        var defaultedToFloatingQuotaV02 = false
        var initialDefaultApplied = true
        var userSelected = true
        var panelCloseRepairApplied = true

        DisplayModeMigration.applyViewDefaults(
            tokenDisplayModeRaw: &mode,
            floatingPanelEnabled: &floatingEnabled,
            statusBarPanelEnabled: &statusBarEnabled,
            pairMigrationApplied: &pairMigrationApplied,
            defaultedToFloating: &defaultedToFloating,
            defaultedToFloatingQuota: &defaultedToFloatingQuota,
            defaultedToFloatingQuotaV02: &defaultedToFloatingQuotaV02,
            initialDefaultApplied: &initialDefaultApplied,
            userSelected: &userSelected,
            panelCloseRepairApplied: &panelCloseRepairApplied
        )

        XCTAssertFalse(floatingEnabled)
        XCTAssertTrue(statusBarEnabled)
        XCTAssertTrue(pairMigrationApplied)
        XCTAssertTrue(defaultedToFloating)
        XCTAssertTrue(defaultedToFloatingQuota)
        XCTAssertTrue(defaultedToFloatingQuotaV02)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexTokenBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
