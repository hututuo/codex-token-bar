import Foundation

enum DisplayModeMigration {
    private static let tokenDisplayModeKey = "tokenDisplayMode"
    private static let initialDefaultAppliedKey = "tokenDisplayModeInitialDefaultAppliedV03"
    private static let userSelectedKey = "tokenDisplayModeUserSelected"
    private static let panelCloseRepairKey = "tokenDisplayModePanelCloseRepairV01"

    static func repairStartup(defaults: UserDefaults = .standard) {
        let rawMode = defaults.string(forKey: tokenDisplayModeKey)
        let mode = rawMode.flatMap(TokenDisplayMode.init(rawValue:))

        if !defaults.bool(forKey: initialDefaultAppliedKey), !defaults.bool(forKey: userSelectedKey) {
            if mode == nil || mode == .off {
                defaults.set(TokenDisplayMode.floating.rawValue, forKey: tokenDisplayModeKey)
            }
            defaults.set(true, forKey: initialDefaultAppliedKey)
            return
        }

        if !defaults.bool(forKey: panelCloseRepairKey), mode == nil || mode == .off {
            defaults.set(TokenDisplayMode.floating.rawValue, forKey: tokenDisplayModeKey)
            defaults.set(false, forKey: userSelectedKey)
        }
        defaults.set(true, forKey: panelCloseRepairKey)
    }

    static func applyViewDefaults(
        tokenDisplayModeRaw: inout String,
        floatingPanelEnabled: inout Bool,
        statusBarPanelEnabled: inout Bool,
        pairMigrationApplied: inout Bool,
        defaultedToFloating: inout Bool,
        defaultedToFloatingQuota: inout Bool,
        defaultedToFloatingQuotaV02: inout Bool,
        initialDefaultApplied: inout Bool,
        userSelected: inout Bool,
        panelCloseRepairApplied: inout Bool
    ) {
        defaultedToFloating = true
        defaultedToFloatingQuota = true
        defaultedToFloatingQuotaV02 = true

        let currentMode = TokenDisplayMode(rawValue: tokenDisplayModeRaw)
        if !initialDefaultApplied && !userSelected,
           currentMode == nil || currentMode == .off {
            tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
        }
        initialDefaultApplied = true

        if !panelCloseRepairApplied,
           currentMode == nil || currentMode == .off {
            tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
            userSelected = false
        }
        panelCloseRepairApplied = true

        guard !pairMigrationApplied else { return }
        let mode = TokenDisplayMode(rawValue: tokenDisplayModeRaw)
        if mode == .statusBar {
            floatingPanelEnabled = false
            statusBarPanelEnabled = true
        } else if mode == .off {
            floatingPanelEnabled = false
            statusBarPanelEnabled = false
        } else {
            floatingPanelEnabled = true
        }
        pairMigrationApplied = true
    }
}
