import Foundation

/// User-configurable cadences for the lightweight usage summary and the
/// derived chart aggregates.  These values deliberately live next to the
/// Swift UI/runtime and do not share storage with quota refresh settings.
struct UsageRefreshCadenceSettings: Equatable {
    static let lightRefreshIntervalStorageKey = "usageLightRefreshIntervalSeconds"
    static let visibleAggregateIntervalStorageKey = "usageVisibleAggregateIntervalMinutes"
    static let backgroundAggregateIntervalStorageKey = "usageBackgroundAggregateIntervalMinutes"

    // Explicit aliases keep the setting names easy to discover from call
    // sites that use the persisted UserDefaults key terminology.
    static let usageLightRefreshIntervalSecondsKey = lightRefreshIntervalStorageKey
    static let usageVisibleAggregateIntervalMinutesKey = visibleAggregateIntervalStorageKey
    static let usageBackgroundAggregateIntervalMinutesKey = backgroundAggregateIntervalStorageKey

    static let lightRefreshIntervalOptions = [60, 150, 300, 600]
    static let aggregateIntervalOptions = [5, 10, 15, 30]

    static let defaultLightRefreshIntervalSeconds = 150
    static let defaultVisibleAggregateIntervalMinutes = 5
    static let defaultBackgroundAggregateIntervalMinutes = 30

    let usageLightRefreshIntervalSeconds: Int
    let usageVisibleAggregateIntervalMinutes: Int
    let usageBackgroundAggregateIntervalMinutes: Int

    init(
        usageLightRefreshIntervalSeconds: Int = defaultLightRefreshIntervalSeconds,
        usageVisibleAggregateIntervalMinutes: Int = defaultVisibleAggregateIntervalMinutes,
        usageBackgroundAggregateIntervalMinutes: Int = defaultBackgroundAggregateIntervalMinutes
    ) {
        self.usageLightRefreshIntervalSeconds = Self.normalizedLightRefreshIntervalSeconds(
            usageLightRefreshIntervalSeconds
        )
        self.usageVisibleAggregateIntervalMinutes = Self.normalizedVisibleAggregateIntervalMinutes(
            usageVisibleAggregateIntervalMinutes
        )
        self.usageBackgroundAggregateIntervalMinutes = Self.normalizedBackgroundAggregateIntervalMinutes(
            usageBackgroundAggregateIntervalMinutes
        )
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            usageLightRefreshIntervalSeconds: readInteger(
                forKey: lightRefreshIntervalStorageKey,
                defaults: defaults,
                allowedValues: lightRefreshIntervalOptions,
                fallback: defaultLightRefreshIntervalSeconds
            ),
            usageVisibleAggregateIntervalMinutes: readInteger(
                forKey: visibleAggregateIntervalStorageKey,
                defaults: defaults,
                allowedValues: aggregateIntervalOptions,
                fallback: defaultVisibleAggregateIntervalMinutes
            ),
            usageBackgroundAggregateIntervalMinutes: readInteger(
                forKey: backgroundAggregateIntervalStorageKey,
                defaults: defaults,
                allowedValues: aggregateIntervalOptions,
                fallback: defaultBackgroundAggregateIntervalMinutes
            )
        )
    }

    static func normalizedLightRefreshIntervalSeconds(_ value: Int) -> Int {
        lightRefreshIntervalOptions.contains(value) ? value : defaultLightRefreshIntervalSeconds
    }

    static func normalizedAggregateIntervalMinutes(_ value: Int) -> Int {
        aggregateIntervalOptions.contains(value) ? value : defaultVisibleAggregateIntervalMinutes
    }

    static func normalizedVisibleAggregateIntervalMinutes(_ value: Int) -> Int {
        aggregateIntervalOptions.contains(value) ? value : defaultVisibleAggregateIntervalMinutes
    }

    static func normalizedBackgroundAggregateIntervalMinutes(_ value: Int) -> Int {
        aggregateIntervalOptions.contains(value) ? value : defaultBackgroundAggregateIntervalMinutes
    }

    static func normalizedLightRawValue(_ rawValue: String?) -> String {
        String(
            normalizedLightRefreshIntervalSeconds(
                Int(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            )
        )
    }

    static func normalizedAggregateRawValue(_ rawValue: String?) -> String {
        String(
            normalizedVisibleAggregateIntervalMinutes(
                Int(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            )
        )
    }

    static func normalizedBackgroundAggregateRawValue(_ rawValue: String?) -> String {
        String(
            normalizedBackgroundAggregateIntervalMinutes(
                Int(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            )
        )
    }

    static func lightRefreshIntervalLabel(_ seconds: Int) -> String {
        switch normalizedLightRefreshIntervalSeconds(seconds) {
        case 60: return "1 分钟"
        case 150: return "2.5 分钟"
        case 300: return "5 分钟"
        case 600: return "10 分钟"
        default: return "2.5 分钟"
        }
    }

    static func aggregateIntervalLabel(_ minutes: Int) -> String {
        "\(normalizedAggregateIntervalMinutes(minutes)) 分钟"
    }

    private static func readInteger(
        forKey key: String,
        defaults: UserDefaults,
        allowedValues: [Int],
        fallback: Int
    ) -> Int {
        guard let object = defaults.object(forKey: key) else { return fallback }

        let candidate: Int?
        if let string = object as? String {
            candidate = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let number = object as? NSNumber {
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else {
                return fallback
            }
            candidate = Int(exactly: doubleValue)
        } else {
            candidate = nil
        }

        guard let candidate, allowedValues.contains(candidate) else { return fallback }
        return candidate
    }
}
