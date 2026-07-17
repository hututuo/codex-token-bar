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
    private static let colorDefaultMigrationKey = "floatingPanelColorDefaultMigrationV01"
    private static let contentDefaultsMigrationKey = "floatingPanelContentDefaultsMigrationV02"
    private static let legacyFloatingPanelGradientStartHex = "#E6F4FF"
    private static let legacyFloatingPanelGradientEndHex = "#D4E8FF"

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

        applyFloatingPanelColorDefaultMigration(defaults: defaults)
        applyFloatingPanelContentDefaultsMigration(defaults: defaults)

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

    private static func applyFloatingPanelColorDefaultMigration(defaults: UserDefaults) {
        guard !defaults.bool(forKey: colorDefaultMigrationKey) else { return }

        let startObject = defaults.object(forKey: FloatingPanelAppearance.startHexKey)
        let endObject = defaults.object(forKey: FloatingPanelAppearance.endHexKey)
        let storedStart = startObject as? String
        let storedEnd = endObject as? String
        let hasNoStoredColors = startObject == nil && endObject == nil
        let stillUsesLegacyDefault = (storedStart == nil || storedStart == legacyFloatingPanelGradientStartHex)
            && (storedEnd == nil || storedEnd == legacyFloatingPanelGradientEndHex)

        if hasNoStoredColors || stillUsesLegacyDefault {
            defaults.set(FloatingPanelAppearance.defaultStartHex, forKey: FloatingPanelAppearance.startHexKey)
            defaults.set(FloatingPanelAppearance.defaultEndHex, forKey: FloatingPanelAppearance.endHexKey)
        }

        defaults.set(true, forKey: colorDefaultMigrationKey)
    }

    private static func applyFloatingPanelContentDefaultsMigration(defaults: UserDefaults) {
        guard !defaults.bool(forKey: contentDefaultsMigrationKey) else { return }

        defaults.set(true, forKey: FloatingPanelContentVisibility.rateAndBarKey)
        defaults.set(true, forKey: FloatingPanelContentVisibility.usageStatusKey)
        defaults.set(true, forKey: FloatingPanelContentVisibility.metricsKey)
        defaults.set(true, forKey: FloatingPanelContentVisibility.quotaKey)
        defaults.set(true, forKey: FloatingPanelContentVisibility.radarKey)
        defaults.set(true, forKey: FloatingPanelContentVisibility.crowdRadarKey)
        defaults.set(FloatingPanelContentVisibility.defaultOrderRaw, forKey: FloatingPanelContentVisibility.orderKey)
        defaults.set(true, forKey: contentDefaultsMigrationKey)
    }
}
