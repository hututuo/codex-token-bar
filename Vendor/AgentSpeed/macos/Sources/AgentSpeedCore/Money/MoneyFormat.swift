import Foundation

/// The two money forms of DESIGN 9: a live value per second, or an amount (today, history, breakdowns, tooltips).
public enum MoneyForm: Sendable {
    case rate
    case amount
}

/// A formatted money value: the digits alone, and the full text (an amount with its symbol in front, a rate followed
/// by ` <symbol>/s`).
public struct FormattedMoney: Equatable, Sendable {
    public let number: String
    public let text: String
    public let symbol: String
}

/// DESIGN 9 money formatting, in decimal arithmetic with half-up rounding, digit for digit like the reference
/// formatter in `spec/tools/prices.py`. Values are never negative and never in scientific notation.
public enum MoneyFormat {
    static let tiny = Decimal(string: "0.0000005")!
    static let million = Decimal(1_000_000)
    public static let belowSmallest = "<0.000001"
    public static let noBreakSpace = "\u{00A0}"

    // MARK: - Values

    /// `costMicroUsd / 1 000 000 × rate`.
    public static func amount(microUsd: Int64, rate: Decimal) -> Decimal {
        Decimal(max(0, microUsd)) * rate / million
    }

    /// A live micro-USD-per-second value in the display currency per second. The `Double` enters as the decimal of
    /// its shortest round-trip text, so both platforms start from the same digits.
    public static func rate(microUsdPerSecond: Double, rate: Decimal) -> Decimal {
        guard microUsdPerSecond.isFinite, microUsdPerSecond > 0,
              let value = Decimal(string: "\(microUsdPerSecond)", locale: Locale(identifier: "en_US_POSIX")) else { return 0 }
        return value * rate / million
    }

    // MARK: - Formatting

    public static func format(_ value: Decimal, currency: Currency, language: String, form: MoneyForm) -> FormattedMoney {
        let number = number(value, digits: currency.digits, form: form)
        let symbol = currency.symbol(language: language)
        let text = form == .amount ? withSymbol(symbol, number) : number + " " + symbol + "/s"
        return FormattedMoney(number: number, text: text, symbol: symbol)
    }

    /// The symbol in front of a number: a no-break space after a symbol that ends in a letter (`CHF 0.42`), and the
    /// `<` of the smallest value before the symbol (`<$0.000001`).
    public static func withSymbol(_ symbol: String, _ number: String) -> String {
        let separator = symbol.last?.isLetter == true ? noBreakSpace : ""
        if number.hasPrefix("<") { return "<" + symbol + separator + number.dropFirst() }
        return symbol + separator + number
    }

    /// The digits of a money value with `digits` decimals for amounts.
    public static func number(_ value: Decimal, digits d: Int, form: MoneyForm) -> String {
        let v = value.isNaN || value < 0 ? Decimal(0) : value
        if v == 0 { return form == .rate || d == 0 ? "0" : "0." + String(repeating: "0", count: d) }
        if v < tiny { return belowSmallest }
        if v < 1 {
            let (w, scale) = roundSignificant(v, 2)
            if w < 1 { return trim(fixed(w, scale: scale), d) }
        }
        if form == .rate, v < 100 {
            let (w, scale) = roundSignificant(v, 3)
            if w < 100 { return trim(fixed(w, scale: scale), d) }
        }
        if v < million {
            let scale = form == .rate ? 0 : d
            let w = round(v, scale: scale)
            if w < million { return group(fixed(w, scale: scale)) }
        }
        return compact(v)
    }

    /// The rate in `rates.status` (DESIGN 9): at least `digits` significant digits, half up, integers grouped and
    /// never fewer decimals than significance needs (`32.55`, `158.1`, `0.8903`, `25,842`).
    public static func significant(_ value: Decimal, digits: Int = 4) -> String {
        guard !value.isNaN, value > 0 else { return "0" }
        var scale = max(0, digits - 1 - adjusted(value))
        var rounded = round(value, scale: scale)
        if adjusted(rounded) > adjusted(value), scale > 0 {
            // Rounding carried into the next power of ten (9.99999 → 10.000): one decimal less.
            scale -= 1
            rounded = round(value, scale: scale)
        }
        return group(fixed(rounded, scale: scale))
    }

    // MARK: - CSV (DESIGN 9 Usage history)

    /// `cost_usd`: exactly 6 decimals from micro-USD.
    public static func csvUSD(microUsd: Int64) -> String {
        fixed(Decimal(max(0, microUsd)) / million, scale: 6)
    }

    /// `cost_<code>`: the amount in the display currency with the currency's `digits` + 2 decimals, half up.
    public static func csv(microUsd: Int64, rate: Decimal, digits: Int) -> String {
        let scale = digits + 2
        return fixed(round(amount(microUsd: microUsd, rate: rate), scale: scale), scale: scale)
    }

    // MARK: - Decimal helpers

    static func round(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, .plain)
        return output
    }

    /// Floor of log10 of a positive value.
    static func adjusted(_ value: Decimal) -> Int {
        var exponent = 0
        var power = Decimal(1)
        while value >= power * 10 {
            power *= 10
            exponent += 1
        }
        while value < power {
            power /= 10
            exponent -= 1
        }
        return exponent
    }

    /// Rounded half up to `digits` significant digits, at most 6 decimals; with the decimals it keeps.
    static func roundSignificant(_ value: Decimal, _ digits: Int) -> (Decimal, scale: Int) {
        let exponent = max(adjusted(value) - digits + 1, -6)
        let scale = -exponent
        return (round(value, scale: scale), scale)
    }

    /// The plain digits of a value already rounded to `scale` (≥ 0) decimals, with exactly that many decimals.
    static func fixed(_ value: Decimal, scale: Int) -> String {
        var power = Decimal(1)
        for _ in 0..<max(0, scale) { power *= 10 }
        let integer = round(value * power, scale: 0)
        var digits = "\(integer)"
        if digits.hasPrefix("-") { digits.removeFirst() }
        guard scale > 0 else { return digits }
        if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
        let split = digits.index(digits.endIndex, offsetBy: -scale)
        return String(digits[..<split]) + "." + String(digits[split...])
    }

    /// Drops trailing fractional zeros beyond `digits` decimals, then pads to `digits` decimals.
    static func trim(_ text: String, _ digits: Int) -> String {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = String(parts[0])
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        while fraction.count > digits, fraction.hasSuffix("0") { fraction.removeLast() }
        if fraction.count < digits { fraction += String(repeating: "0", count: digits - fraction.count) }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }

    /// Thousands separators in the whole part.
    static func group(_ text: String) -> String {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = String(parts[0])
        var grouped = ""
        while whole.count > 3 {
            grouped = "," + whole.suffix(3) + grouped
            whole.removeLast(3)
        }
        return whole + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// METRICS 7 for values of at least one million: `1.28M`, `12.8M`, `128M`, `1.28B`, …
    static func compact(_ value: Decimal) -> String {
        for (unit, scale) in [("M", Decimal(1_000_000)), ("B", Decimal(1_000_000_000))] {
            let x = value / scale
            for (limit, places) in [(Decimal(10), 2), (Decimal(100), 1), (Decimal(1000), 0)] {
                let r = round(x, scale: places)
                if x < limit, r < limit { return fixed(r, scale: places) + unit }
            }
            if unit == "B" { return group(fixed(round(x, scale: 0), scale: 0)) + "B" }
        }
        return fixed(value, scale: 0)
    }
}
