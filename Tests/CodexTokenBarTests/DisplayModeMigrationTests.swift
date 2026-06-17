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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexTokenBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
