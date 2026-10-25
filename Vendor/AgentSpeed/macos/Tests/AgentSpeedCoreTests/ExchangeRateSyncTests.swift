import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Exchange rate sync")
struct ExchangeRateSyncTests {
    static let providers = ExchangeRateProvider.all
    static let erAPI = providers[0].url
    static let jsDelivr = providers[1].url
    static let pages = providers[2].url
    static let frankfurter = providers[3].url
    /// 2026-10-22T12:00Z.
    static let noon = Date(timeIntervalSince1970: 1_792_670_400)
    static let day: TimeInterval = 86400

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func erAPIBody(twd: Double = 32.41, unix: Int = 1_792_627_351) -> Data {
        json(["result": "success", "base_code": "USD", "time_last_update_unix": unix,
              "rates": ["USD": 1, "TWD": twd, "JPY": 158.1, "CNY": 6.689327]])
    }

    static func currencyAPIBody(twd: Double = 32.55, date: String = "2026-10-22") -> Data {
        json(["date": date, "usd": ["usd": 1, "twd": twd, "jpy": 157.7, "cny": 6.67476008, "btc": 0.0000091]])
    }

    static func frankfurterBody(_ rates: [String: Double], date: String = "2026-10-21") -> Data {
        json(["amount": 1.0, "base": "USD", "date": date, "rates": rates])
    }

    struct Harness {
        let directory: TempDirectory
        let transport = ScriptedTransport()
        let clock = TestClock(ExchangeRateSyncTests.noon)
        var store: ExchangeRateStore { ExchangeRateStore(appDataDirectory: directory.url) }
        var sync: ExchangeRateSync {
            ExchangeRateSync(store: store, transport: transport, userAgent: "AgentSpeed/9.9.9 (macOS)", now: clock.function)
        }

        init() throws {
            directory = try TempDirectory()
        }

        func storeRates(_ rates: [String: Decimal], provider: ExchangeRateProvider, dateMs: Int64, fetchedMs: Int64,
                        etag: String? = nil) throws {
            let set = ExchangeRateSet(provider: provider.host, url: provider.url.absoluteString, dateMs: dateMs, fetchedMs: fetchedMs,
                                      rates: rates.merging(["USD": 1]) { old, _ in old })
            try store.save(StoredRates(set, etags: etag.map { [provider.url.absoluteString: $0] } ?? [:]))
        }
    }

    static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    @Test func theFirstProviderWinsAndIsStored() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.erAPI, body: Self.erAPIBody(), etag: "W/\"1\"")
        guard case .updated(let set) = await harness.sync.run(selected: "TWD") else {
            Issue.record("not accepted")
            return
        }
        #expect(set.provider == "open.er-api.com")
        #expect(set.needsAttribution)
        #expect(set.rates["TWD"] == Decimal(string: "32.41"))
        #expect(set.dateMs == 1_792_627_351_000)
        #expect(harness.transport.requestedURLs == [Self.erAPI.absoluteString])
        let request = try #require(harness.transport.requests.first)
        #expect(!request.url.absoluteString.contains("TWD") && !request.url.absoluteString.lowercased().contains("twd"),
                "the request never names the selected currency")
        #expect(request.maxBytes == 256 << 10)
        #expect(request.allowedHosts == ["open.er-api.com", "cdn.jsdelivr.net", "latest.currency-api.pages.dev", "api.frankfurter.dev"])
        let stored = try #require(harness.store.load())
        #expect(stored.provider == "open.er-api.com")
        #expect(stored.etags == [Self.erAPI.absoluteString: "W/\"1\""])
        #expect(stored.fetchedMs == Self.ms(Self.noon))
        #expect(stored.rateSet.rates == set.rates)
    }

    @Test func providersFallBackInOrderAndThePagesMirrorOnlyWhenJsDelivrFails() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.erAPI, status: 429)
        harness.transport.reply(Self.jsDelivr, body: Self.currencyAPIBody())
        guard case .updated(let set) = await harness.sync.run(selected: "TWD") else {
            Issue.record("not accepted")
            return
        }
        #expect(set.provider == "cdn.jsdelivr.net")
        #expect(!set.needsAttribution)
        #expect(harness.transport.requestedURLs == [Self.erAPI.absoluteString, Self.jsDelivr.absoluteString])

        let mirror = try Harness()
        mirror.transport.reply(Self.jsDelivr, status: 503)
        mirror.transport.reply(Self.pages, body: Self.currencyAPIBody())
        guard case .updated(let fromPages) = await mirror.sync.run(selected: "TWD") else {
            Issue.record("not accepted")
            return
        }
        #expect(fromPages.provider == "latest.currency-api.pages.dev")
        #expect(mirror.transport.requestedURLs == [Self.erAPI, Self.jsDelivr, Self.pages].map(\.absoluteString))
    }

    @Test func aRateOutsideTheBoundsRejectsTheProvider() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.erAPI, body: Self.erAPIBody(twd: 97.2))
        harness.transport.reply(Self.jsDelivr, body: Self.currencyAPIBody())
        guard case .updated(let set) = await harness.sync.run(selected: "TWD") else {
            Issue.record("not accepted")
            return
        }
        #expect(set.provider == "cdn.jsdelivr.net", "checked against the bundled fallback rate")
    }

    @Test func staleRatesNeedTwoProvidersAndKeepTheFirstOnesRates() async throws {
        let harness = try Harness()
        let monthAgo = Self.noon.addingTimeInterval(-40 * Self.day)
        try harness.storeRates(["TWD": 20], provider: Self.providers[1], dateMs: Self.ms(monthAgo), fetchedMs: Self.ms(monthAgo))
        harness.transport.reply(Self.erAPI, body: Self.erAPIBody(twd: 32.41))
        harness.transport.reply(Self.jsDelivr, body: Self.currencyAPIBody(twd: 32.55))
        guard case .updated(let set) = await harness.sync.run(selected: "TWD") else {
            Issue.record("not accepted")
            return
        }
        #expect(set.provider == "open.er-api.com")
        #expect(set.rates["TWD"] == Decimal(string: "32.41"))
        #expect(harness.transport.requestedURLs == [Self.erAPI.absoluteString, Self.jsDelivr.absoluteString])
    }

    @Test func staleRatesWithDisagreeingProvidersFail() async throws {
        let harness = try Harness()
        let monthAgo = Self.noon.addingTimeInterval(-40 * Self.day)
        try harness.storeRates(["TWD": 32], provider: Self.providers[1], dateMs: Self.ms(monthAgo), fetchedMs: Self.ms(monthAgo))
        harness.transport.reply(Self.erAPI, body: Self.erAPIBody(twd: 45))
        harness.transport.reply(Self.jsDelivr, body: Self.currencyAPIBody(twd: 32.55))
        harness.transport.reply(Self.frankfurter, body: Self.frankfurterBody(["JPY": 157.9]))
        guard case .failed = await harness.sync.run(selected: "TWD") else {
            Issue.record("disagreeing providers were accepted")
            return
        }
        #expect(!harness.transport.requestedURLs.contains(Self.pages.absoluteString), "2a answered, so its mirror is not asked")
        #expect(harness.store.load()?.rateSet.rates["TWD"] == 32, "the stored rates stay")
    }

    @Test func frankfurterNeedsTheSelectedCurrencyAndKeepsTheOthers() async throws {
        let harness = try Harness()
        let yesterday = Self.noon.addingTimeInterval(-Self.day)
        try harness.storeRates(["TWD": Decimal(string: "32.4")!, "JPY": 158], provider: Self.providers[0],
                               dateMs: Self.ms(yesterday) - Int64(Self.day * 1000), fetchedMs: Self.ms(yesterday))
        harness.transport.reply(Self.frankfurter, body: Self.frankfurterBody(["JPY": 157.88, "CNY": 6.6761]))
        guard case .updated(let set) = await harness.sync.run(selected: "JPY") else {
            Issue.record("not accepted")
            return
        }
        #expect(set.provider == "api.frankfurter.dev")
        #expect(set.rates["JPY"] == Decimal(string: "157.88"))
        #expect(set.rates["TWD"] == Decimal(string: "32.4"), "missing currencies keep their previous rates")
        #expect(set.rates["USD"] == 1)

        let missing = try Harness()
        missing.transport.reply(Self.frankfurter, body: Self.frankfurterBody(["JPY": 157.88]))
        guard case .failed(let reason) = await missing.sync.run(selected: "TWD") else {
            Issue.record("Frankfurter without the selected currency was accepted")
            return
        }
        #expect(reason == "selected currency missing")
    }

    @Test func a304ConfirmsTheStoredRates() async throws {
        let harness = try Harness()
        let yesterday = Self.noon.addingTimeInterval(-Self.day)
        try harness.storeRates(["TWD": 32], provider: Self.providers[0], dateMs: Self.ms(yesterday), fetchedMs: Self.ms(yesterday),
                               etag: "\"e1\"")
        harness.transport.reply(Self.erAPI, status: 304)
        guard case .unchanged(let set) = await harness.sync.run(selected: "TWD") else {
            Issue.record("304 not treated as unchanged")
            return
        }
        #expect(harness.transport.requests.first?.ifNoneMatch == "\"e1\"")
        #expect(set.fetchedMs == Self.ms(Self.noon))
        #expect(harness.store.load()?.fetchedMs == Self.ms(Self.noon))
        #expect(set.dateMs == Self.ms(yesterday))
    }

    @Test func ratesNeverGoBackInTime() async throws {
        let harness = try Harness()
        try harness.storeRates(["TWD": 32], provider: Self.providers[1], dateMs: Self.ms(Self.noon), fetchedMs: Self.ms(Self.noon))
        harness.transport.reply(Self.erAPI, body: Self.erAPIBody())
        harness.transport.reply(Self.jsDelivr, body: Self.currencyAPIBody(date: "2026-10-21"))
        harness.transport.reply(Self.frankfurter, body: Self.frankfurterBody(["TWD": 32.5], date: "2026-10-21"))
        guard case .failed = await harness.sync.run(selected: "TWD") else {
            Issue.record("older rates were accepted")
            return
        }
    }

    @Test func scheduleRules() {
        let launch = Self.noon
        let now = launch.addingTimeInterval(5)
        #expect(ExchangeRateSync.nextAttempt(launchedAt: launch, fetchedAt: nil, lastFailure: nil, now: now) == launch.addingTimeInterval(30))
        let fresh = launch.addingTimeInterval(-3600)
        #expect(ExchangeRateSync.nextAttempt(launchedAt: launch, fetchedAt: fresh, lastFailure: nil, now: now)
                == fresh.addingTimeInterval(Self.day))
        #expect(ExchangeRateSync.nextAttempt(launchedAt: launch, fetchedAt: nil, lastFailure: now, now: now) == now.addingTimeInterval(3600))
        #expect(ExchangeRateSync.fetchesOnSelection(fetchedAt: nil, lastFailure: nil, now: now))
        #expect(!ExchangeRateSync.fetchesOnSelection(fetchedAt: fresh, lastFailure: nil, now: now))
        #expect(ExchangeRateSync.fetchesOnSelection(fetchedAt: now.addingTimeInterval(-Self.day), lastFailure: nil, now: now))
        #expect(!ExchangeRateSync.fetchesOnSelection(fetchedAt: nil, lastFailure: now.addingTimeInterval(-60), now: now))
    }

    @Test func anUnreadableStoreIsDiscarded() throws {
        let directory = try TempDirectory()
        let store = ExchangeRateStore(appDataDirectory: directory.url)
        try directory.write("rates.json", "{")
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
