import Foundation

struct AccountQuotaRefreshCadence: Identifiable, Hashable {
    static let storageKey = "accountQuotaRefreshCadenceSeconds"

    static let thirtySeconds = AccountQuotaRefreshCadence(seconds: 30, label: "30 秒")
    static let oneMinute = AccountQuotaRefreshCadence(seconds: 60, label: "1 分钟")
    static let threeMinutes = AccountQuotaRefreshCadence(seconds: 180, label: "3 分钟")
    static let fiveMinutes = AccountQuotaRefreshCadence(seconds: 300, label: "5 分钟")
    static let tenMinutes = AccountQuotaRefreshCadence(seconds: 600, label: "10 分钟")

    static let allCases: [AccountQuotaRefreshCadence] = [
        .thirtySeconds,
        .oneMinute,
        .threeMinutes,
        .fiveMinutes,
        .tenMinutes
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
