import Foundation

enum QuotaHistoryFilterSettings {
    static let enabledKey = "filterQuotaHistoryAnomalies"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Existing installations have no key: protection remains enabled.
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
