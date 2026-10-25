import Foundation

/// Units per 1 USD of the supported currencies (USD = 1), as accepted from a provider (NETWORK 4).
public struct ExchangeRateSet: Equatable, Sendable {
    /// The provider's host (`open.er-api.com`, `cdn.jsdelivr.net`, `latest.currency-api.pages.dev`,
    /// `api.frankfurter.dev`), shown in the status line.
    public var provider: String
    public var url: String
    /// The rates' own date (Unix ms; provider 1: its update time, others: the date at 00:00 UTC).
    public var dateMs: Int64
    /// When the rates were accepted (or last confirmed by a `304`).
    public var fetchedMs: Int64
    public var rates: [String: Decimal]

    public init(provider: String, url: String, dateMs: Int64, fetchedMs: Int64, rates: [String: Decimal]) {
        self.provider = provider
        self.url = url
        self.dateMs = dateMs
        self.fetchedMs = fetchedMs
        self.rates = rates
    }

    /// ExchangeRate-API's terms require the attribution link while its rates are in use (NETWORK 4).
    public var needsAttribution: Bool { provider == ExchangeRates.erAPIHost }
}

/// Response parsing and acceptance checks of NETWORK 4, exactly like `parse_rates` and `accept_rates` of
/// `spec/tools/prices.py`.
public enum ExchangeRates {
    /// Provider ids of `spec/fixtures/rates-cases.json`.
    public enum Shape: String, Sendable, CaseIterable {
        case erAPI = "open.er-api.com"
        /// fawazahmed0 currency API (jsDelivr and its Cloudflare Pages mirror).
        case currencyAPI = "currency-api"
        case frankfurter
    }

    public static let erAPIHost = "open.er-api.com"
    public static let dayMs: Int64 = 86_400_000
    public static let staleReferenceMs: Int64 = 30 * dayMs
    public static let maxFutureMs: Int64 = 2 * dayMs

    public enum ParseError: Error, Equatable, Sendable {
        case invalid(String)
    }

    /// The rates' date (Unix ms) and the supported currencies' rates (codes upper-cased, USD = 1).
    public static func parse(
        _ shape: Shape,
        body: JSONValue,
        supported: Set<String>
    ) throws(ParseError) -> (dateMs: Int64, rates: [String: Decimal]) {
        guard body.object != nil else { throw .invalid("not an object") }
        let dateMs: Int64
        var raw: [String: JSONValue]
        switch shape {
        case .erAPI:
            guard body["result"]?.string == "success", body["base_code"]?.string == "USD" else {
                throw .invalid("not a successful USD response")
            }
            guard var stamp = body["time_last_update_unix"]?.literal?.decimal, stamp > 0, stamp < 1e15 else {
                throw .invalid("no update time")
            }
            var seconds = Decimal()
            NSDecimalRound(&seconds, &stamp, 0, .down)
            dateMs = Int64(truncating: NSDecimalNumber(decimal: seconds)) * 1000
            guard let rates = body["rates"]?.object else { throw .invalid("no rates") }
            raw = rates
        case .currencyAPI:
            guard let date = body["date"]?.string, PriceTableValidator.isDate(date), let ms = UTCDay.instantMs(date) else {
                throw .invalid("no date")
            }
            dateMs = ms
            guard let rates = body["usd"]?.object else { throw .invalid("no rates") }
            raw = rates
        case .frankfurter:
            guard body["base"]?.string == "USD", let date = body["date"]?.string, PriceTableValidator.isDate(date),
                  let ms = UTCDay.instantMs(date) else { throw .invalid("not a USD response with a date") }
            dateMs = ms
            switch body["rates"] {
            case nil, .null?: raw = [:]
            case .object(let rates)?: raw = rates
            default: throw .invalid("no rates")
            }
            raw["USD"] = .number(JSONLiteral("1"))
        }
        var rates: [String: Decimal] = [:]
        for (code, value) in raw {
            let upper = code.uppercased()
            guard supported.contains(upper) else { continue }
            guard let rate = value.literal?.decimal, rate > 0 else { throw .invalid("bad rate for \(upper)") }
            rates[upper] = rate
        }
        rates["USD"] = 1
        return (dateMs, rates)
    }

    /// The last accepted rates for check 4: their date, when they were accepted and the rates.
    public struct Reference: Equatable, Sendable {
        public var dateMs: Int64
        public var acceptedMs: Int64
        public var rates: [String: Decimal]

        public init(dateMs: Int64, acceptedMs: Int64, rates: [String: Decimal]) {
            self.dateMs = dateMs
            self.acceptedMs = acceptedMs
            self.rates = rates
        }
    }

    public enum Verdict: Equatable, Sendable {
        case accepted
        /// Check 4 has no usable reference (the last rates are older than 30 days): a second provider must agree.
        case needsSecondProvider
        case rejected(String)

        public var isAccepted: Bool { self == .accepted }
    }

    /// Checks 3–5 for the selected currency.
    public static func check(
        dateMs: Int64,
        rates: [String: Decimal],
        selected: String,
        nowMs: Int64,
        last: Reference?,
        fallback: [String: Decimal]?,
        other: [String: Decimal]? = nil
    ) -> Verdict {
        if dateMs > nowMs + maxFutureMs { return .rejected("date in the future") }
        if let last, dateMs < last.dateMs { return .rejected("older than the stored rates") }
        guard let new = rates[selected] else { return .rejected("selected currency missing") }
        let reference: Decimal? = if let last {
            nowMs - last.acceptedMs <= staleReferenceMs ? last.rates[selected] : nil
        } else {
            fallback?[selected]
        }
        if let reference {
            return reference / 2 <= new && new <= reference * 2 ? .accepted : .rejected("outside x0.5..x2")
        }
        guard let other, let second = other[selected] else { return .needsSecondProvider }
        let gap = new > second ? new - second : second - new
        return gap <= second * Decimal(string: "0.03")! ? .accepted : .rejected("providers disagree")
    }
}
