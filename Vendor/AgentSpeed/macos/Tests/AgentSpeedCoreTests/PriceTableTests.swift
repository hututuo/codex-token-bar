import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Price table")
struct PriceTableTests {
    static func table(_ relative: String) throws -> PriceTable {
        let data = try Data(contentsOf: Fixtures.root.appendingPathComponent(relative))
        return try PriceTable.load(data).get()
    }

    static func cases() throws -> [String: Any] { try Fixtures.json("price-cases.json") }

    static func tables() throws -> [String: PriceTable] {
        let names = try #require(try cases()["tables"] as? [String: String])
        return try names.mapValues { try table("\($0)") }
    }

    static func usage(_ tokens: [String: Any]) -> TokenUsage {
        TokenUsage(
            input: tokens.int("input"), cachedInput: tokens.int("cachedInput"), cacheWriteInput: tokens.int("cacheWriteInput"),
            cacheWrite1hInput: tokens.int("cacheWrite1hInput"), output: tokens.int("output"), reasoning: tokens.int("reasoning")
        )
    }

    static func atMs(_ spec: [String: Any]) -> Int64? {
        spec.string("at").flatMap(UTCDay.instantMs)
    }

    // MARK: - Bundled assets

    @Test func bundledTableValidatesWithItsOwnTests() throws {
        let table = PriceBook.bundled
        let spec = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Fixtures.root.deletingLastPathComponent().appendingPathComponent("assets/prices.json"))
        ) as? [String: Any]
        #expect(table.version == spec?.int("version"))
        #expect(table.models.count == (spec?["models"] as? [Any])?.count)
        #expect(table.tests.count == (spec?["tests"] as? [Any])?.count)
        #expect(!table.tests.isEmpty)
    }

    @Test func embeddedAssetsMatchTheSpecFiles() throws {
        let assets = Fixtures.root.deletingLastPathComponent().appendingPathComponent("assets")
        for (name, embedded) in [("prices", BundledPriceAssets.prices), ("currencies", BundledPriceAssets.currencies)] {
            var text = try String(contentsOf: assets.appendingPathComponent("\(name).json"), encoding: .utf8)
            if text.hasSuffix("\n") { text.removeLast() }
            #expect(embedded == text, "BundledPriceAssets.swift is stale: run macos/scripts/sync-prices.py")
        }
    }

    // MARK: - Fixture cases (METRICS 9.2, 9.3, 9.7)

    @Test func fixtureTablesValidate() throws {
        let tables = try Self.tables()
        #expect(tables.count == 2)
        #expect(tables["v1"]?.version == 1)
        #expect(tables["v2"]?.version == 2)
    }

    @Test func resolveCases() throws {
        let tables = try Self.tables()
        let cases = try #require(try Self.cases()["resolve"] as? [[String: Any]])
        #expect(cases.count >= 40)
        for (index, spec) in cases.enumerated() {
            let table = try #require(tables[spec.string("table") ?? ""])
            let resolution = table.resolver.resolve(model: spec.string("model"), provider: spec.string("provider"))
            #expect(table.label(of: resolution) == spec.string("expect"), "resolve[\(index)] \(spec["model"] ?? "nil")")
        }
    }

    @Test func costCases() throws {
        let tables = try Self.tables()
        let cases = try #require(try Self.cases()["cost"] as? [[String: Any]])
        #expect(cases.count >= 20)
        for spec in cases {
            let name = spec.string("name") ?? "?"
            let table = try #require(tables[spec.string("table") ?? ""])
            let usage = Self.usage(try #require(spec["tokens"] as? [String: Any]))
            let fast = spec["fast"] as? Bool ?? false
            let at = Self.atMs(spec)
            let model = spec.string("model")
            let provider = spec.string("provider")
            var pico: Int64?
            var tier: Int?
            let resolution = table.resolver.resolve(model: model, provider: provider)
            switch resolution {
            case .priced(let index, let byName):
                if let pricing = table.models[index].pricing(endMs: at, fast: byName || fast) {
                    (pico, tier) = ResponseCost.picoUsd(usage: usage, pricing: pricing)
                }
            case .free:
                pico = 0
            case .unknown:
                break
            }
            let micro = table.cost(model: model, provider: provider, usage: usage, endMs: at, fast: fast)
            let expect = try #require(spec["expect"] as? [String: Any])
            if expect.keys.contains("costPicoUsd") {
                #expect(pico == expect.int64("costPicoUsd"), "\(name) costPicoUsd")
            }
            #expect(micro == expect.int64("costMicroUsd"), "\(name) costMicroUsd")
            if expect.keys.contains("tier") {
                #expect(tier == (expect["tier"] as? NSNumber)?.intValue, "\(name) tier")
            }
        }
    }

    @Test func dayCases() throws {
        let tables = try Self.tables()
        let cases = try #require(try Self.cases()["days"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for spec in cases {
            let name = spec.string("name") ?? "?"
            let bindings = (spec["bindings"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
            let book = PriceBook(tables: Array(tables.values), bindings: bindings)
            let day = try #require(spec.string("date"))
            let cost = book.cost(
                model: spec.string("model"), provider: spec.string("provider"),
                usage: Self.usage(try #require(spec["tokens"] as? [String: Any])), endMs: Self.atMs(spec), fast: false, day: day
            )
            #expect(cost == spec.int64("costMicroUsd"), "\(name) cost")
            #expect(book.version(forDay: day) == spec.int("version"), "\(name) version")
        }
    }

    // MARK: - Rejections (NETWORK 3 validation)

    static func bundledJSON() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(BundledPriceAssets.prices.utf8)) as? [String: Any])
    }

    static func load(_ object: [String: Any]) throws -> Result<PriceTable, PriceTableError> {
        PriceTable.load(try JSONSerialization.data(withJSONObject: object))
    }

    static func errors(_ result: Result<PriceTable, PriceTableError>) -> [String] {
        if case .failure(.invalid(let errors)) = result { return errors }
        return []
    }

    @Test func aNewerSchemaIsReportedAsSuch() throws {
        var table = try Self.bundledJSON()
        table["schema"] = 2
        let result = try Self.load(table)
        guard case .failure(let error) = result else {
            Issue.record("schema 2 was accepted")
            return
        }
        #expect(error.isNewerSchema)
    }

    @Test func notJSONAndOversizedAreRejected() {
        guard case .failure(.notJSON) = PriceTable.load(Data("[1, 2".utf8)) else {
            Issue.record("broken JSON accepted")
            return
        }
        guard case .failure(.notJSON) = PriceTable.load(Data("[]".utf8)) else {
            Issue.record("a non-object accepted")
            return
        }
        guard case .failure(.tooLarge) = PriceTable.load(Data(count: PriceTable.maxBytes + 1)) else {
            Issue.record("an oversized body accepted")
            return
        }
    }

    @Test func tooManyDecimalsAreRejected() throws {
        var table = try Self.bundledJSON()
        var models = try #require(table["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { $0["prices"] != nil })
        var prices = try #require(models[index]["prices"] as? [String: Any])
        prices["input"] = NSDecimalNumber(string: "1.0000001")
        models[index]["prices"] = prices
        table["models"] = models
        #expect(Self.errors(try Self.load(table)).contains { $0.contains("more than 6 decimals") })
    }

    @Test func outOfRangePricesAreRejected() throws {
        var table = try Self.bundledJSON()
        var models = try #require(table["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { $0["prices"] != nil })
        var prices = try #require(models[index]["prices"] as? [String: Any])
        prices["output"] = 10_001
        models[index]["prices"] = prices
        table["models"] = models
        #expect(Self.errors(try Self.load(table)).contains { $0.contains("out of range") })
    }

    @Test func duplicateAliasesAndShadowingUnknownsAreRejected() throws {
        var table = try Self.bundledJSON()
        var models = try #require(table["models"] as? [[String: Any]])
        let firstId = try #require(models[0]["id"] as? String)
        models[1]["aliases"] = ((models[1]["aliases"] as? [String]) ?? []) + [firstId]
        table["models"] = models
        #expect(Self.errors(try Self.load(table)).contains { $0.contains("is used 2 times") })

        var shadowing = try Self.bundledJSON()
        var unknown = try #require(shadowing["unknown"] as? [[String: Any]])
        unknown.append(["match": "exact", "value": firstId, "reason": "test"])
        shadowing["unknown"] = unknown
        #expect(Self.errors(try Self.load(shadowing)).contains { $0.contains("shadows") })
    }

    @Test func tiersMustAscendWithTheBaseFields() throws {
        var table = try Self.bundledJSON()
        var models = try #require(table["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { $0["tiers"] != nil })
        var tiers = try #require(models[index]["tiers"] as? [[String: Any]])
        tiers.append(tiers[0])
        models[index]["tiers"] = tiers
        table["models"] = models
        #expect(Self.errors(try Self.load(table)).contains { $0.contains("greater than the previous threshold") })
    }

    @Test func failingOwnTestsRejectTheTable() throws {
        var table = try Self.bundledJSON()
        var tests = try #require(table["tests"] as? [[String: Any]])
        tests.append(["model": "claude-opus-5-5", "expect": "gpt-5.5"])
        table["tests"] = tests
        let errors = Self.errors(try Self.load(table))
        #expect(errors.contains { $0.contains("expected gpt-5.5") }, "\(errors)")
    }

    @Test func overlappingPeriodsAreRejected() throws {
        var table = try Self.bundledJSON()
        var models = try #require(table["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { ($0["periods"] as? [Any])?.isEmpty == false })
        var periods = try #require(models[index]["periods"] as? [[String: Any]])
        periods.append(periods[0])
        models[index]["periods"] = periods
        table["models"] = models
        #expect(Self.errors(try Self.load(table)).contains { $0.contains("overlaps another period") })
    }

    // MARK: - Rules

    @Test func offPeakFollowsUTCWindowsWeekdaysAndHolidays() throws {
        let rule = OffPeakRule(
            peakWindows: [60..<240, 360..<600], peakWeekdays: [1, 2, 3, 4, 5], offPeakDates: ["2026-10-01"],
            pricing: TieredPrices(prices: PriceSet(input: 1, cachedInput: 1, cacheWrite: 1, cacheWrite1h: 1, output: 1), tiers: [])
        )
        let monday = try #require(UTCDay.instantMs("2026-10-19T02:00Z"))
        #expect(!rule.isOffPeak(atMs: monday), "Monday 02:00 UTC is peak")
        #expect(rule.isOffPeak(atMs: monday + 2 * 3_600_000), "04:00 is the exclusive end")
        #expect(!rule.isOffPeak(atMs: monday + 4 * 3_600_000), "06:00 starts the second window")
        #expect(rule.isOffPeak(atMs: try #require(UTCDay.instantMs("2026-10-18T02:00Z"))), "Sunday")
        #expect(rule.isOffPeak(atMs: try #require(UTCDay.instantMs("2026-10-01T02:00Z"))), "a holiday")
    }

    @Test func utcCalendarArithmetic() throws {
        #expect(UTCDay.instantMs("1970-01-01") == 0)
        #expect(UTCDay.instantMs("2026-10-20T23:59Z") == 1_792_540_740_000)
        #expect(UTCDay.instantMs("2026-02-29") == nil)
        #expect(UTCDay.instantMs("2026-10-20T24:00Z") == nil)
        #expect(UTCDay(ms: 1_792_540_799_999).label == "2026-10-20")
        #expect(UTCDay(ms: 1_792_540_800_000).label == "2026-10-21")
        #expect(UTCDay(ms: 0).isoWeekday == 4)
        #expect(UTCDay(ms: -1).label == "1969-12-31")
    }

    @Test func costClassesAreClamped() {
        let usage = TokenUsage(input: 500_000_000, cachedInput: 0, cacheWriteInput: 0, output: 500_000_000)
        let classes = ResponseCost.Classes(usage)
        #expect(classes.uncached == ResponseCost.maxClassTokens)
        #expect(classes.output == ResponseCost.maxClassTokens)
        let price = PriceSet(input: 10_000_000_000, cachedInput: 0, cacheWrite: 0, cacheWrite1h: 0, output: 10_000_000_000)
        let pico = ResponseCost.picoUsd(usage: usage, pricing: TieredPrices(prices: price, tiers: [])).pico
        #expect(pico == 2 * ResponseCost.maxClassTokens * 10_000_000_000)
        #expect(ResponseCost.microUsd(499_999) == 0)
        #expect(ResponseCost.microUsd(500_000) == 1)
    }

    @Test func bindingsKeepTheirTableAndRepairMissingOnes() throws {
        let tables = try Self.tables()
        let book = PriceBook(tables: Array(tables.values))
        #expect(book.currentVersion == 2)
        #expect(book.restore(bindings: ["2026-10-01": 1, "2026-10-02": 9]) == ["2026-10-02"])
        #expect(book.version(forDay: "2026-10-01") == 1)
        #expect(book.version(forDay: "2026-10-02") == 2)
        #expect(book.version(forDay: "2026-10-03") == 2)
        #expect(book.takeNewBindings() == ["2026-10-02": 2, "2026-10-03": 2])
        #expect(book.takeNewBindings().isEmpty)
        #expect(!book.add(try #require(tables["v1"])))
        book.clearBindings()
        #expect(book.boundVersion(forDay: "2026-10-01") == nil)
    }
}
