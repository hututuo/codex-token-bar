import Foundation

enum TokenRateScaleSettings {
    static let key = "tokenRateFullScale"
    static let defaultValue = 200.0
    static let range = 50.0...500.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func displayValue(_ value: Double) -> String {
        "\(Int(clamped(value).rounded()))/s"
    }
}
