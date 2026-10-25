import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Exchange rates")
struct ExchangeRateTests {
    static func cases() throws -> [String: Any] { try Fixtures.json("rates-cases.json") }

    static func decimals(_ object: Any?) -> [String: Decimal]? {
        guard let map = object as? [String: String] else { return nil }
        return map.mapValues { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))! }
    }

    static func body(_ object: Any) throws -> JSONValue {
        try JSONParser.parse(JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }

    @Test func parseCases() throws {
        let cases = try Self.cases()
        let supported = Set(try #require(cases["supported"] as? [String]))
        let parse = try #require(cases["parse"] as? [[String: Any]])
        #expect(parse.count >= 6)
        for spec in parse {
            let name = spec.string("name") ?? "?"
            let shape = try #require(ExchangeRates.Shape(rawValue: spec.string("provider") ?? ""), "\(name) provider")
            let body = try Self.body(try #require(spec["body"]))
            let got = try? ExchangeRates.parse(shape, body: body, supported: supported)
            guard let expect = spec["expect"] as? [String: Any] else {
                #expect(got == nil, "\(name) should be rejected")
                continue
            }
            let parsed = try #require(got, "\(name) was rejected")
            #expect(parsed.dateMs == expect.int64("dateMs"), "\(name) dateMs")
            #expect(parsed.rates == Self.decimals(expect["rates"]), "\(name) rates")
        }
    }

    @Test func acceptCases() throws {
        let accept = try #require(try Self.cases()["accept"] as? [[String: Any]])
        #expect(accept.count >= 8)
        for spec in accept {
            let name = spec.string("name") ?? "?"
            let last = (spec["last"] as? [String: Any]).map {
                ExchangeRates.Reference(
                    dateMs: $0.int64("dateMs") ?? 0, acceptedMs: $0.int64("acceptedMs") ?? 0, rates: Self.decimals($0["rates"]) ?? [:]
                )
            }
            let verdict = ExchangeRates.check(
                dateMs: try #require(spec.int64("dateMs")),
                rates: try #require(Self.decimals(spec["rates"])),
                selected: try #require(spec.string("selected")),
                nowMs: try #require(spec.int64("nowMs")),
                last: last,
                fallback: Self.decimals(spec["fallback"]),
                other: Self.decimals(spec["other"])
            )
            #expect(verdict.isAccepted == (spec["accept"] as? Bool), "\(name): \(verdict)")
        }
    }

    @Test func staleReferencesNeedASecondProvider() {
        let verdict = ExchangeRates.check(
            dateMs: 100 * ExchangeRates.dayMs, rates: ["TWD": 45], selected: "TWD", nowMs: 100 * ExchangeRates.dayMs,
            last: ExchangeRates.Reference(dateMs: 0, acceptedMs: 0, rates: ["TWD": 32]), fallback: ["TWD": 32]
        )
        #expect(verdict == .needsSecondProvider)
    }

    @Test func ratesInUseFallBackToTheBundledRates() {
        let fallback = CurrencyTable.bundled.fallbackRates
        let bundled = RatesInUse(stored: nil, fallback: fallback)
        #expect(bundled.isFallback)
        #expect(!bundled.needsAttribution)
        #expect(bundled.rate(for: "TWD") == fallback.rates["TWD"])
        #expect(bundled.rate(for: "USD") == 1)
        let accepted = RatesInUse(
            stored: ExchangeRateSet(provider: "open.er-api.com", url: "https://open.er-api.com/v6/latest/USD", dateMs: 0,
                                    fetchedMs: 0, rates: ["USD": 1, "TWD": 32]),
            fallback: fallback
        )
        #expect(accepted.needsAttribution)
        #expect(accepted.rate(for: "TWD") == 32)
        #expect(accepted.rate(for: "JPY") == fallback.rates["JPY"], "a missing currency takes its bundled rate")
        #expect(!accepted.isStale(nowMs: 7 * ExchangeRates.dayMs))
        #expect(accepted.isStale(nowMs: 7 * ExchangeRates.dayMs + 1))
    }

    @Test func storedRatesRoundTripExactly() throws {
        let set = ExchangeRateSet(
            provider: "cdn.jsdelivr.net", url: "https://x", dateMs: 5, fetchedMs: 6,
            rates: ["USD": 1, "CNY": Decimal(string: "6.67476008")!, "IDR": Decimal(string: "18040.7")!]
        )
        let data = try JSONEncoder().encode(StoredRates(set, etags: ["https://x": "\"abc\""]))
        let decoded = try JSONDecoder().decode(StoredRates.self, from: data)
        #expect(decoded.rateSet == set)
        #expect(decoded.etags == ["https://x": "\"abc\""])
    }
}
