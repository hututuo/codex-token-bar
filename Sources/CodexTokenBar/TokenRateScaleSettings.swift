import Foundation

enum TokenRateScaleSettings {
    static let key = "tokenRateFullScale"
    static let initializationKey = "tokenRateFullScaleInitializedV092"
    static let defaultValue = 150.0
    static let range = 50.0...500.0

    static func initializeForV092(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: initializationKey) else { return }
        defaults.set(defaultValue, forKey: key)
        defaults.set(true, forKey: initializationKey)
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value.isFinite ? value : defaultValue, range.lowerBound), range.upperBound)
    }

    static func displayValue(_ value: Double) -> String {
        "\(Int(clamped(value).rounded()))/s"
    }
}
