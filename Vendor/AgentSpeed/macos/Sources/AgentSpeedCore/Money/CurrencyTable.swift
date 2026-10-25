import Foundation

/// A display currency (DESIGN 9, `spec/assets/currencies.json`).
public struct Currency: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    /// ISO 4217 code.
    public let code: String
    /// Decimals of an amount.
    public let digits: Int
    /// The prefix shown in front of a number.
    public let symbol: String
    /// Per UI language (`zh-Hant`, `zh-Hans`, `en`, `ja`) overrides of `symbol`.
    public let symbols: [String: String]
    /// Rank in the picker's common group; nil = the alphabetical group.
    public let common: Int?

    public init(code: String, digits: Int, symbol: String, symbols: [String: String] = [:], common: Int? = nil) {
        self.code = code
        self.digits = digits
        self.symbol = symbol
        self.symbols = symbols
        self.common = common
    }

    /// `symbols[language]` when present, else `symbol` (`$` in English, `US$` elsewhere).
    public func symbol(language: String) -> String {
        symbols[language] ?? symbol
    }

    public static let usdCode = "USD"
}

/// The bundled units per 1 USD used until the first accepted rate fetch (NETWORK 4).
public struct FallbackRates: Equatable, Sendable {
    /// `YYYY-MM-DD`.
    public let date: String
    public let source: String
    public let rates: [String: Decimal]

    /// 00:00 UTC of `date`.
    public var dateMs: Int64 { UTCDay.instantMs(date) ?? 0 }
}

/// `spec/assets/currencies.json`: the supported currencies, their digits and symbols, and the bundled rates.
public struct CurrencyTable: Sendable {
    public static let languages = ["zh-Hant", "zh-Hans", "en", "ja"]
    /// The UI language's home currencies, right after USD in the common group (DESIGN 9).
    public static let homeCurrencies: [String: [String]] = [
        "zh-Hant": ["TWD", "HKD", "MOP"],
        "zh-Hans": ["CNY"],
        "ja": ["JPY"],
    ]

    public let currencies: [Currency]
    public let fallbackRates: FallbackRates
    private let byCode: [String: Currency]

    public init(currencies: [Currency], fallbackRates: FallbackRates) {
        self.currencies = currencies
        self.fallbackRates = fallbackRates
        var byCode: [String: Currency] = [:]
        for currency in currencies { byCode[currency.code] = currency }
        self.byCode = byCode
    }

    /// The table bundled with this build.
    public static let bundled: CurrencyTable = {
        guard let table = try? CurrencyTable.parse(Data(BundledPriceAssets.currencies.utf8)) else {
            fatalError("The bundled currency table does not parse; run python3 spec/tools/prices.py")
        }
        return table
    }()

    public enum ParseError: Error, Equatable, Sendable {
        case invalid(String)
    }

    public static func parse(_ data: Data) throws -> CurrencyTable {
        guard let root = try? JSONParser.parse(data), root["schema"]?.int64 == 1,
              let list = root["currencies"]?.array else { throw ParseError.invalid("schema or currencies") }
        var currencies: [Currency] = []
        for entry in list {
            guard let code = entry["code"]?.string, let digits = entry["digits"]?.int64,
                  let symbol = entry["symbol"]?.string else { throw ParseError.invalid("currency entry") }
            var symbols: [String: String] = [:]
            for (language, value) in entry["symbols"]?.object ?? [:] {
                if let text = value.string { symbols[language] = text }
            }
            currencies.append(Currency(
                code: code, digits: Int(digits), symbol: symbol, symbols: symbols, common: entry["common"]?.int64.map { Int($0) }
            ))
        }
        guard let fallback = root["fallbackRates"], let date = fallback["date"]?.string,
              let source = fallback["source"]?.string, let raw = fallback["rates"]?.object else {
            throw ParseError.invalid("fallbackRates")
        }
        var rates: [String: Decimal] = [:]
        for (code, value) in raw {
            guard let rate = value.literal?.decimal, rate > 0 else { throw ParseError.invalid("fallback rate \(code)") }
            rates[code] = rate
        }
        return CurrencyTable(currencies: currencies, fallbackRates: FallbackRates(date: date, source: source, rates: rates))
    }

    public func currency(_ code: String) -> Currency? { byCode[code] }

    /// The currency for `code`, else USD.
    public func currencyOrUSD(_ code: String) -> Currency {
        byCode[code] ?? byCode[Currency.usdCode]!
    }

    public var codes: Set<String> { Set(byCode.keys) }

    // MARK: - Picker

    /// The picker's common group: USD, the UI language's home currencies, then the remaining `common` ranks.
    public func commonGroup(language: String) -> [Currency] {
        var order: [String] = [Currency.usdCode]
        for code in Self.homeCurrencies[language] ?? [] where !order.contains(code) && byCode[code] != nil {
            order.append(code)
        }
        let ranked = currencies.filter { $0.common != nil }.sorted { ($0.common ?? 0) < ($1.common ?? 0) }
        for currency in ranked where !order.contains(currency.code) { order.append(currency.code) }
        return order.compactMap { byCode[$0] }
    }

    /// Every other currency, sorted by `localizedName` (then code).
    public func otherGroup(language: String, localizedName: (Currency) -> String) -> [Currency] {
        let common = Set(commonGroup(language: language).map(\.code))
        return currencies.filter { !common.contains($0.code) }.sorted { lhs, rhs in
            let order = localizedName(lhs).localizedStandardCompare(localizedName(rhs))
            return order == .orderedSame ? lhs.code < rhs.code : order == .orderedAscending
        }
    }

    /// Search results as one ranked list (DESIGN 9): code prefix matches first, then matches at the start of any word
    /// of the localized or English name or of the symbol (`nt` finds TWD through `NT$`); case-, width- and
    /// diacritic-insensitive. Within a rank the picker order is kept (common group first, then the others by
    /// localized name). An empty query returns nothing.
    public func search(
        _ query: String,
        language: String,
        localizedName: (Currency) -> String,
        englishName: (Currency) -> String
    ) -> [Currency] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let ordered = commonGroup(language: language) + otherGroup(language: language, localizedName: localizedName)
        var codeMatches: [Currency] = []
        var nameMatches: [Currency] = []
        for currency in ordered {
            if Self.fold(currency.code).hasPrefix(needle) {
                codeMatches.append(currency)
            } else if [localizedName(currency), englishName(currency), currency.symbol(language: language), currency.symbol]
                        .contains(where: { Self.wordStarts(Self.fold($0), with: needle) }) {
                nameMatches.append(currency)
            }
        }
        return codeMatches + nameMatches
    }

    /// Lowercased, width-folded (full-width letters → ASCII), without diacritics.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Whether `needle` starts any word of `haystack`: the whole text, after a space, punctuation or symbol, or at
    /// any CJK character (CJK names have no spaces, so every character starts a word).
    static func wordStarts(_ haystack: String, with needle: String) -> Bool {
        let scalars = Array(haystack.unicodeScalars)
        let target = Array(needle.unicodeScalars)
        guard !target.isEmpty, scalars.count >= target.count else { return false }
        for start in 0...(scalars.count - target.count) {
            let isBoundary = start == 0 || !isWordScalar(scalars[start - 1]) || isIdeographic(scalars[start])
            if isBoundary, scalars[start..<(start + target.count)].elementsEqual(target) { return true }
        }
        return false
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }
}
