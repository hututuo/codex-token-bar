import Foundation
import os

/// One exchange-rate source of NETWORK 4, in fallback order.
public struct ExchangeRateProvider: Equatable, Sendable {
    public let shape: ExchangeRates.Shape
    public let url: URL

    public var host: String { url.host() ?? "" }

    /// 1 → 2a → 2b → 3. 2b (the project's Cloudflare Pages mirror) is only asked when 2a fails.
    public static let all: [ExchangeRateProvider] = [
        ExchangeRateProvider(shape: .erAPI, url: URL(string: "https://open.er-api.com/v6/latest/USD")!),
        ExchangeRateProvider(
            shape: .currencyAPI,
            url: URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json")!
        ),
        ExchangeRateProvider(shape: .currencyAPI, url: URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json")!),
        ExchangeRateProvider(shape: .frankfurter, url: URL(string: "https://api.frankfurter.dev/v1/latest?base=USD")!),
    ]

    public static let allowedHosts: Set<String> = Set(all.map(\.host))
    /// ExchangeRate-API's attribution link (its terms require it while its rates are in use).
    public static let attributionURL = URL(string: "https://www.exchangerate-api.com")!
}

/// `<app data>/rates.json` (NETWORK 4): `{provider, url, date, fetchedMs, etags, rates}`; `date` is the rates' own
/// date in Unix ms and rates are decimal strings, so nothing is rounded on the way to disk.
public struct StoredRates: Codable, Equatable, Sendable {
    public var provider: String
    public var url: String
    public var date: Int64
    public var fetchedMs: Int64
    public var etags: [String: String]
    public var rates: [String: String]

    public init(_ set: ExchangeRateSet, etags: [String: String]) {
        provider = set.provider
        url = set.url
        date = set.dateMs
        fetchedMs = set.fetchedMs
        self.etags = etags
        rates = set.rates.mapValues { "\($0)" }
    }

    public var rateSet: ExchangeRateSet {
        var decoded: [String: Decimal] = [:]
        for (code, text) in rates {
            if let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 { decoded[code] = value }
        }
        return ExchangeRateSet(provider: provider, url: url, dateMs: date, fetchedMs: fetchedMs, rates: decoded)
    }
}

public struct ExchangeRateStore: Sendable {
    static let logger = Logger(subsystem: "io.github.zoefix.agentspeed", category: "rates")

    public let fileURL: URL

    public init(appDataDirectory: URL) {
        fileURL = appDataDirectory.appendingPathComponent("rates.json")
    }

    public func load() -> StoredRates? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredRates.self, from: data), stored.rates["USD"] != nil else {
            Self.logger.error("Stored exchange rates are unreadable; deleted")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return stored
    }

    public func save(_ stored: StoredRates) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}

/// The rates every displayed amount uses (METRICS 9.8): the last accepted rates, else the bundled fallback.
public struct RatesInUse: Equatable, Sendable {
    public static let staleAfterMs: Int64 = 7 * ExchangeRates.dayMs

    public var rates: [String: Decimal]
    /// The rates' own date (Unix ms).
    public var dateMs: Int64
    /// The provider's host; nil for the bundled fallback.
    public var provider: String?
    public var fetchedMs: Int64?
    private let fallback: [String: Decimal]

    public init(stored: ExchangeRateSet?, fallback: FallbackRates) {
        self.fallback = fallback.rates
        if let stored {
            rates = stored.rates
            dateMs = stored.dateMs
            provider = stored.provider
            fetchedMs = stored.fetchedMs
        } else {
            rates = fallback.rates
            dateMs = fallback.dateMs
            provider = nil
            fetchedMs = nil
        }
    }

    public var isFallback: Bool { provider == nil }
    public var needsAttribution: Bool { provider == ExchangeRates.erAPIHost }

    /// Units of `code` per 1 USD (USD = 1); a currency the accepted list lacks takes its bundled rate.
    public func rate(for code: String) -> Decimal {
        if code == Currency.usdCode { return 1 }
        return rates[code] ?? fallback[code] ?? 1
    }

    /// Older than 7 days by the rates' date (`rates.stale`); conversion continues with them.
    public func isStale(nowMs: Int64) -> Bool {
        nowMs - dateMs > Self.staleAfterMs
    }
}

public enum ExchangeRateOutcome: Equatable, Sendable {
    case updated(ExchangeRateSet)
    /// A `304` confirmed the stored rates.
    case unchanged(ExchangeRateSet)
    case failed(reason: String)
}

/// One round of NETWORK 4: 1 → 2a → (2b when 2a failed) → 3, stopping at the first response that passes checks 1–5.
/// Every request asks for the complete USD-based list, never for the selected currency.
public struct ExchangeRateSync: Sendable {
    public static let maxBytes = 256 << 10
    public static let launchDelay: TimeInterval = 30
    public static let interval: TimeInterval = 24 * 3600
    public static let retryDelay: TimeInterval = 3600
    public static let checkInterval: TimeInterval = 3600

    let store: ExchangeRateStore
    let transport: any HTTPTransport
    let userAgent: String
    let currencies: CurrencyTable
    let providers: [ExchangeRateProvider]
    let now: @Sendable () -> Date

    public init(
        store: ExchangeRateStore,
        transport: any HTTPTransport,
        userAgent: String,
        currencies: CurrencyTable = .bundled,
        providers: [ExchangeRateProvider] = ExchangeRateProvider.all,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.userAgent = userAgent
        self.currencies = currencies
        self.providers = providers
        self.now = now
    }

    /// The next automatic round while a non-USD currency is selected: 30 s after launch, then 24 h after the last
    /// accepted fetch, and never sooner than 1 h after a failed round. Stamps in the future count as now.
    public static func nextAttempt(launchedAt: Date, fetchedAt: Date?, lastFailure: Date?, now: Date) -> Date {
        var due = launchedAt.addingTimeInterval(launchDelay)
        if let fetchedAt { due = max(due, min(fetchedAt, now).addingTimeInterval(interval)) }
        if let lastFailure { due = max(due, min(lastFailure, now).addingTimeInterval(retryDelay)) }
        return due
    }

    /// Selecting a non-USD currency fetches at once when the stored rates are missing or older than 24 h, unless a
    /// round failed within the last hour.
    public static func fetchesOnSelection(fetchedAt: Date?, lastFailure: Date?, now: Date) -> Bool {
        if let lastFailure, now.timeIntervalSince(lastFailure) < retryDelay { return false }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= interval
    }

    private struct Candidate {
        var provider: ExchangeRateProvider
        var dateMs: Int64
        var rates: [String: Decimal]
        var etag: String?
    }

    public func run(selected: String) async -> ExchangeRateOutcome {
        let previous = store.load()
        let previousSet = previous?.rateSet
        let nowMs = PriceTableSync.milliseconds(now())
        let supported = currencies.codes
        let fallback = currencies.fallbackRates.rates
        let last = previousSet.map { ExchangeRates.Reference(dateMs: $0.dateMs, acceptedMs: $0.fetchedMs, rates: $0.rates) }
        var pending: Candidate?
        var failure = "no response"
        var currencyAPIAnswered = false
        for provider in providers {
            if provider.shape == .currencyAPI, currencyAPIAnswered { continue }
            let url = provider.url.absoluteString
            let etag = previous?.url == url ? previous?.etags[url] : nil
            let request = HTTPFetchRequest(
                url: provider.url, accept: "application/json", ifNoneMatch: etag, userAgent: userAgent,
                maxBytes: Self.maxBytes, allowedHosts: ExchangeRateProvider.allowedHosts
            )
            let response: HTTPFetchResponse
            do {
                response = try await transport.get(request)
            } catch {
                failure = (error as? HTTPFetchError)?.reason ?? "transport error"
                log(provider, failure)
                continue
            }
            if response.status == 304, let previous, var set = previousSet, previous.url == url {
                set.fetchedMs = nowMs
                try? store.save(StoredRates(set, etags: previous.etags))
                log(provider, "304, unchanged")
                return .unchanged(set)
            }
            guard (200..<300).contains(response.status) else {
                failure = "HTTP \(response.status)"
                log(provider, failure)
                continue
            }
            let parsed: (dateMs: Int64, rates: [String: Decimal])
            do {
                guard let body = try? JSONParser.parse(response.body) else { throw ExchangeRates.ParseError.invalid("not JSON") }
                parsed = try ExchangeRates.parse(provider.shape, body: body, supported: supported)
            } catch {
                failure = "invalid response"
                log(provider, "\(response.body.count) bytes rejected (\(error))")
                continue
            }
            if provider.shape == .currencyAPI { currencyAPIAnswered = true }
            var rates = parsed.rates
            if provider.shape == .frankfurter {
                // Check 5: only with the selected currency; its missing currencies keep their previous rates.
                guard rates[selected] != nil else {
                    failure = "selected currency missing"
                    log(provider, failure)
                    continue
                }
                rates = (previousSet?.rates ?? fallback).merging(rates) { _, new in new }
            }
            let candidate = Candidate(provider: provider, dateMs: parsed.dateMs, rates: rates, etag: response.etag)
            if let first = pending {
                let verdict = ExchangeRates.check(
                    dateMs: first.dateMs, rates: first.rates, selected: selected, nowMs: nowMs, last: last, fallback: fallback,
                    other: candidate.rates
                )
                if verdict.isAccepted {
                    log(first.provider, "confirmed by \(provider.host)")
                    return accept(first, previous: previous, nowMs: nowMs)
                }
                log(first.provider, "not confirmed by \(provider.host)")
                pending = nil
            }
            switch ExchangeRates.check(
                dateMs: candidate.dateMs, rates: candidate.rates, selected: selected, nowMs: nowMs, last: last, fallback: fallback
            ) {
            case .accepted:
                return accept(candidate, previous: previous, nowMs: nowMs)
            case .needsSecondProvider:
                log(provider, "needs a second provider (the last rates are older than 30 days)")
                pending = candidate
            case .rejected(let reason):
                failure = reason
                log(provider, "rejected: \(reason)")
            }
        }
        if pending != nil { failure = "needs a second provider" }
        ExchangeRateStore.logger.notice("Exchange rates: every provider failed (\(failure, privacy: .public))")
        return .failed(reason: failure)
    }

    private func accept(_ candidate: Candidate, previous: StoredRates?, nowMs: Int64) -> ExchangeRateOutcome {
        let set = ExchangeRateSet(
            provider: candidate.provider.host, url: candidate.provider.url.absoluteString, dateMs: candidate.dateMs,
            fetchedMs: nowMs, rates: candidate.rates
        )
        var etags = previous?.etags ?? [:]
        etags[set.url] = candidate.etag
        do {
            try store.save(StoredRates(set, etags: etags))
        } catch {
            ExchangeRateStore.logger.error("Exchange rates could not be saved")
        }
        log(candidate.provider, "accepted, \(set.rates.count) currencies")
        return .updated(set)
    }

    private func log(_ provider: ExchangeRateProvider, _ message: String) {
        ExchangeRateStore.logger.notice("Exchange rates \(provider.host, privacy: .public): \(message, privacy: .public)")
    }
}
