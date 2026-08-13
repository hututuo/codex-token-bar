import Foundation

struct AccountQuotaRefreshCadence: Identifiable, Hashable {
    static let storageKey = "accountQuotaRefreshCadenceSeconds"

    static let thirtySeconds = AccountQuotaRefreshCadence(seconds: 30, label: "30 秒")
    static let oneMinute = AccountQuotaRefreshCadence(seconds: 60, label: "1 分钟")
    static let allCases: [AccountQuotaRefreshCadence] = [
        .thirtySeconds,
        .oneMinute
    ]

    static let defaultValue = oneMinute
    static let defaultRawValue = oneMinute.rawValue

    let seconds: TimeInterval
    let label: String

    var id: String { rawValue }
    var rawValue: String { String(Int(seconds)) }

    static func value(for rawValue: String) -> AccountQuotaRefreshCadence {
        allCases.first { $0.rawValue == rawValue } ?? defaultValue
    }

    static func storedValue(in userDefaults: UserDefaults = .standard) -> AccountQuotaRefreshCadence {
        value(for: userDefaults.string(forKey: storageKey) ?? defaultRawValue)
    }
}

enum AccountQuotaAutomaticRefreshPolicy {
    private static let maximumSuccessCooldown: TimeInterval = 30

    static func successCooldown(for automaticRefreshInterval: TimeInterval) -> TimeInterval {
        min(maximumSuccessCooldown, max(0, automaticRefreshInterval / 2))
    }

    static func shouldSkipAutomaticRefresh(
        snapshotIsAvailable: Bool,
        recentSuccessAge: TimeInterval?,
        automaticRefreshInterval: TimeInterval
    ) -> Bool {
        guard snapshotIsAvailable, let recentSuccessAge else { return false }
        return recentSuccessAge < successCooldown(for: automaticRefreshInterval)
    }
}
