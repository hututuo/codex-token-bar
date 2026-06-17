import Foundation

enum DisplayModeMigration {
    private static let tokenDisplayModeKey = "tokenDisplayMode"
    private static let pairMigrationKey = "displaySurfacePairMigrationV01"
    private static let defaultedToFloatingKey = "tokenDisplayModeDefaultedToFloatingV021"
    private static let defaultedToFloatingQuotaKey = "tokenDisplayModeDefaultedToFloatingQuotaV01"
    private static let defaultedToFloatingQuotaV02Key = "tokenDisplayModeDefaultedToFloatingQuotaV02"
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
        floatingPanelEnabled: inout Bool,
        statusBarPanelEnabled: inout Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: defaultedToFloatingKey)
        defaults.set(true, forKey: defaultedToFloatingQuotaKey)
        defaults.set(true, forKey: defaultedToFloatingQuotaV02Key)

        var mode = storedMode(defaults: defaults)
        if !defaults.bool(forKey: initialDefaultAppliedKey),
           !defaults.bool(forKey: userSelectedKey),
           mode == nil || mode == .off {
            defaults.set(TokenDisplayMode.floating.rawValue, forKey: tokenDisplayModeKey)
            mode = .floating
        }
        defaults.set(true, forKey: initialDefaultAppliedKey)

        if !defaults.bool(forKey: panelCloseRepairKey),
           mode == nil || mode == .off {
            defaults.set(TokenDisplayMode.floating.rawValue, forKey: tokenDisplayModeKey)
            defaults.set(false, forKey: userSelectedKey)
            mode = .floating
        }
        defaults.set(true, forKey: panelCloseRepairKey)

        guard !defaults.bool(forKey: pairMigrationKey) else { return }
        mode = storedMode(defaults: defaults) ?? .floating
        if mode == .statusBar {
            floatingPanelEnabled = false
            statusBarPanelEnabled = true
        } else if mode == .off {
            floatingPanelEnabled = false
            statusBarPanelEnabled = false
        } else {
            floatingPanelEnabled = true
        }
        defaults.set(true, forKey: pairMigrationKey)
    }

    private static func storedMode(defaults: UserDefaults) -> TokenDisplayMode? {
        defaults.string(forKey: tokenDisplayModeKey).flatMap(TokenDisplayMode.init(rawValue:))
    }
}
