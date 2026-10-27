import Foundation

/// Byte formatting shared by every surface (METRICS 10.11): decimal units, three significant digits, a value that
/// rounds to 1000 moves to the next unit, half-up rounding, a no-break space between number and unit.
public enum TrafficFormat {
    /// The number and the unit separately, for fixed cells (DESIGN 10, Formatting).
    public struct Parts: Equatable, Sendable {
        public var number: String
        public var unit: String

        public init(number: String, unit: String) {
            self.number = number
            self.unit = unit
        }

        public var text: String { number + "\u{00A0}" + unit }
    }

    public static let rateUnits = ["B/s", "KB/s", "MB/s", "GB/s"]
    public static let bitRateUnits = ["b/s", "Kb/s", "Mb/s", "Gb/s"]
    public static let totalUnits = ["B", "KB", "MB", "GB", "TB"]

    public static func rateParts(_ bytesPerSecond: Double, bits: Bool = false) -> Parts {
        bits ? parts(bytesPerSecond * 8, units: bitRateUnits) : parts(bytesPerSecond, units: rateUnits)
    }

    public static func totalParts(_ bytes: Double) -> Parts {
        parts(bytes, units: totalUnits)
    }

    public static func rate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
        rateParts(bytesPerSecond, bits: bits).text
    }

    public static func total(_ bytes: Double) -> String {
        totalParts(bytes).text
    }

    public static func total(_ bytes: Int64) -> String {
        total(Double(bytes))
    }

    /// Works on the decimal digits of the value, so `9.995` rounds up as written rather than as its binary neighbour.
    static func parts(_ value: Double, units: [String]) -> Parts {
        var x = Decimal(value.isFinite ? max(0, value) : 0)
        // Decimal(Double) carries binary noise (9995 → 9994.999…); 15 significant digits are what the Double holds.
        x = rounded(x, scale: 15 - magnitude(x))
        var unit = 0
        while true {
            let shown: Decimal
            let digits: Int
            if unit == 0 {
                shown = rounded(x, scale: 0)
                digits = 0
            } else if x < Decimal(string: "9.995")! {
                shown = rounded(x, scale: 2)
                digits = 2
            } else if x < Decimal(string: "99.95")! {
                shown = rounded(x, scale: 1)
                digits = 1
            } else {
                shown = rounded(x, scale: 0)
                digits = 0
            }
            if shown < 1000 || unit == units.count - 1 {
                return Parts(number: text(shown, digits: digits), unit: units[unit])
            }
            x /= 1000
            unit += 1
        }
    }

    private static func magnitude(_ x: Decimal) -> Int {
        guard x > 0 else { return 0 }
        var m = 0
        var v = x
        while v >= 10 { v /= 10; m += 1 }
        while v < 1 { v *= 10; m -= 1 }
        return m
    }

    private static func rounded(_ x: Decimal, scale: Int) -> Decimal {
        var input = x
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func text(_ value: Decimal, digits: Int) -> String {
        let number = NSDecimalNumber(decimal: value)
        guard digits > 0 else { return number.stringValue }
        return String(format: digits == 1 ? "%.1f" : "%.2f", locale: posix, number.doubleValue)
    }
}
