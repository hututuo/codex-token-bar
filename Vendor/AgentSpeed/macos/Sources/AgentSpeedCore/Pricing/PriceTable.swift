import Foundation

/// One price set in integer micro-USD per million tokens (= pico-USD per token), with the defaults of METRICS 9.1
/// applied: a missing `cachedInput` or `cacheWrite` is `input`, a missing `cacheWrite1h` is `cacheWrite`.
public struct PriceSet: Equatable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWrite: Int64
    public var cacheWrite1h: Int64
    public var output: Int64

    public init(input: Int64, cachedInput: Int64, cacheWrite: Int64, cacheWrite1h: Int64, output: Int64) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.output = output
    }
}

/// A long-context tier: replaces the prices of a whole response whose `input` is above `above`.
public struct PriceTier: Equatable, Sendable {
    public var above: Int64
    public var prices: PriceSet
}

/// Base prices with their optional tiers.
public struct TieredPrices: Equatable, Sendable {
    public var prices: PriceSet
    public var tiers: [PriceTier]

    /// The price set for a response of `inputTokens`, and the index of the tier used (nil = the base prices).
    public func select(inputTokens: Int64) -> (prices: PriceSet, tier: Int?) {
        var chosen = prices
        var index: Int?
        for (position, tier) in tiers.enumerated() where inputTokens > tier.above {
            chosen = tier.prices
            index = position
        }
        return (chosen, index)
    }
}

/// DeepSeek-style off-peak pricing (METRICS 9.1): peak only inside a UTC window of a peak weekday that is not an
/// off-peak date.
public struct OffPeakRule: Equatable, Sendable {
    /// `[start, end)` in minutes of the UTC day.
    public var peakWindows: [Range<Int>]
    /// ISO weekdays, 1 = Monday.
    public var peakWeekdays: Set<Int>
    /// UTC dates `YYYY-MM-DD` that are off-peak all day.
    public var offPeakDates: Set<String>
    public var pricing: TieredPrices

    public func isOffPeak(atMs ms: Int64) -> Bool {
        let day = UTCDay(ms: ms)
        if offPeakDates.contains(day.label) || !peakWeekdays.contains(day.isoWeekday) { return true }
        return !peakWindows.contains { $0.contains(day.minuteOfDay) }
    }
}

/// Prices of a model, or of one of its periods.
public struct ModelPricing: Equatable, Sendable {
    public var base: TieredPrices
    public var offPeak: OffPeakRule?
}

/// Prices that apply while `fromMs ≤ endMs < toMs` (METRICS 9.1 periods).
public struct PricePeriod: Equatable, Sendable {
    public var fromMs: Int64?
    public var toMs: Int64?
    public var pricing: ModelPricing

    public func covers(_ ms: Int64) -> Bool {
        (fromMs.map { $0 <= ms } ?? true) && (toMs.map { ms < $0 } ?? true)
    }
}

public struct PriceModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var name: String
    public var status: String
    /// `"free": true`: every response costs a known 0.
    public var isFree: Bool
    /// Nil exactly when the model is free.
    public var pricing: ModelPricing?
    public var periods: [PricePeriod]
    public var fast: TieredPrices?
    public var aliases: [String]
    public var source: String
    public var checked: String
    public var note: String?

    /// The prices for one response (METRICS 9.1, 9.3): fast prices for a fast response, else the period covering
    /// `endMs`, then its off-peak prices when `endMs` is off-peak. Nil when a fast response has no fast price.
    public func pricing(endMs: Int64?, fast: Bool) -> TieredPrices? {
        if fast { return self.fast }
        guard var applied = pricing else { return nil }
        if let endMs {
            if let period = periods.first(where: { $0.covers(endMs) }) { applied = period.pricing }
            if let rule = applied.offPeak, rule.isOffPeak(atMs: endMs) { return rule.pricing }
        }
        return applied.base
    }
}

public struct PriceProvider: Equatable, Sendable {
    public var name: String
    public var url: String
}

/// The lists that drive model resolution (METRICS 9.2).
public struct PriceNormalization: Equatable, Sendable {
    public struct Rewrite: Equatable, Sendable {
        public var prefix: String
        public var to: String
    }

    public struct Modifier: Equatable, Sendable {
        public var prefix: String
        public var suffixes: [String]
    }

    public var freeProviders: [String]
    public var cloudSuffixes: [String]
    public var bedrockRegions: [String]
    public var bedrockVendors: [String]
    public var freeSuffixes: [String]
    public var variantSuffixes: [String]
    public var fastSuffixes: [String]
    public var rewrites: [Rewrite]
    public var dateSuffixPrefixes: [String]
    public var modifierSuffixes: [Modifier]
    public var dotHyphenPrefixes: [String]
}

/// An id known to have no public price.
public struct UnknownModelRule: Equatable, Sendable {
    public var isPrefix: Bool
    public var value: String
    public var reason: String
}

/// A row of the table's own `tests` (METRICS 9.1).
public struct PriceTableTest: Equatable, Sendable {
    public var model: String?
    public var provider: String?
    public var expect: String
}

/// A validated price table (METRICS 9.1). Build one with `PriceTable.load`.
public struct PriceTable: Sendable {
    public static let supportedSchema = 1
    /// Downloads and stored copies above this size are rejected (NETWORK 3).
    public static let maxBytes = 1 << 20

    public let version: Int
    public let updated: String
    public let providers: [String: PriceProvider]
    public let normalize: PriceNormalization
    public let models: [PriceModel]
    public let unknown: [UnknownModelRule]
    public let tests: [PriceTableTest]
    /// The document as loaded, for the history store's copies (METRICS 9.7) and the synced file.
    public let data: Data
    public let resolver: ModelResolver

    init(
        version: Int, updated: String, providers: [String: PriceProvider], normalize: PriceNormalization,
        models: [PriceModel], unknown: [UnknownModelRule], tests: [PriceTableTest], data: Data
    ) {
        self.version = version
        self.updated = updated
        self.providers = providers
        self.normalize = normalize
        self.models = models
        self.unknown = unknown
        self.tests = tests
        self.data = data
        resolver = ModelResolver(normalize: normalize, models: models, unknown: unknown)
    }

    /// Integer micro-USD of one response, or nil when its price is unknown (METRICS 9.3). Free models cost 0.
    public func cost(model: String?, provider: String?, usage: TokenUsage, endMs: Int64?, fast: Bool) -> Int64? {
        switch resolver.resolve(model: model, provider: provider) {
        case .free:
            return 0
        case .unknown:
            return nil
        case .priced(let index, let fastByName):
            guard let pricing = models[index].pricing(endMs: endMs, fast: fastByName || fast) else { return nil }
            return ResponseCost.microUsd(ResponseCost.picoUsd(usage: usage, pricing: pricing).pico)
        }
    }

    public func cost(of record: ResponseRecord) -> Int64? {
        cost(model: record.model, provider: record.provider, usage: record.usage, endMs: record.endMs, fast: record.fast)
    }
}

/// UTC calendar facts of an instant, from integer arithmetic.
struct UTCDay: Equatable {
    static let msPerDay: Int64 = 86_400_000

    let daysSinceEpoch: Int64
    let msOfDay: Int64

    init(ms: Int64) {
        var days = ms / Self.msPerDay
        var rest = ms % Self.msPerDay
        if rest < 0 {
            days -= 1
            rest += Self.msPerDay
        }
        daysSinceEpoch = days
        msOfDay = rest
    }

    var minuteOfDay: Int { Int(msOfDay / 60_000) }

    /// 1970-01-01 was a Thursday (ISO 4).
    var isoWeekday: Int {
        let offset = Int((daysSinceEpoch + 3) % 7)
        return (offset < 0 ? offset + 7 : offset) + 1
    }

    /// `YYYY-MM-DD` (proleptic Gregorian, civil-from-days).
    var label: String {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    /// Unix ms of `YYYY-MM-DD` (00:00 UTC) or `YYYY-MM-DDTHH:MMZ`; nil for any other text or an impossible date.
    static func instantMs(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 || bytes.count == 17 else { return nil }
        func number(_ range: Range<Int>) -> Int64? {
            var value: Int64 = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              (1...12).contains(month), year >= 1 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths: [Int64] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= lengths[Int(month - 1)] else { return nil }
        var minutes: Int64 = 0
        if bytes.count == 17 {
            guard bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: "Z"),
                  let hour = number(11..<13), let minute = number(14..<16), hour < 24, minute < 60 else { return nil }
            minutes = hour * 60 + minute
        }
        // days-from-civil
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return days * msPerDay + minutes * 60_000
    }
}
