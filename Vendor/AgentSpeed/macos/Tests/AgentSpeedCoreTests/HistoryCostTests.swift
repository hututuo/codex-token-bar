import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Daily history cost")
struct HistoryCostTests {
    static let utc = TimeZone(identifier: "UTC")!

    /// A Claude transcript with one response per `(id, model, output)`, ending at `base + 10 s × index + 4 s`.
    static func claude(_ responses: [(String, String, Int)], base: Int64 = 1_792_490_400) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for (index, (id, model, output)) in responses.enumerated() {
            let start = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(base + Int64(index) * 10)))
            let end = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(base + Int64(index) * 10 + 4)))
            lines.append(#"{"type":"user","cwd":"/w/p","message":{"role":"user","content":"q"},"timestamp":"\#(start)"}"#)
            lines.append(#"{"type":"assistant","cwd":"/w/p","message":{"id":"\#(id)","model":"\#(model)","stop_reason":"end_turn","usage":{"input_tokens":5000,"output_tokens":\#(output)}},"timestamp":"\#(end)"}"#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func tables() throws -> (v1: PriceTable, v2: PriceTable) {
        (try PriceTableTests.table("prices/v1.json"), try PriceTableTests.table("prices/v2.json"))
    }

    struct Scratch {
        let directory: TempDirectory
        let configuration: MonitorConfiguration
        let storePath: String

        init() throws {
            directory = try TempDirectory()
            configuration = MonitorConfiguration(
                enabledSources: [.claudeCode],
                claudeRoot: directory.file("claude"),
                opencodeRoot: directory.file("opencode")
            )
            storePath = directory.file("store/history.sqlite").path
        }

        /// A new launch: a fresh book with `tables`, restored from the store by the analyzer.
        func run(_ tables: [PriceTable]) throws -> (HistoryAnalyzer.Report, [DailyUsage], PriceBook) {
            let book = PriceBook(tables: tables)
            let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: storePath), pricing: book)
            let report = try analyzer.run(configuration: configuration, options: HistoryAnalyzer.Options(timeZone: HistoryCostTests.utc))
            return (report, analyzer.days(sources: configuration.enabledSources), book)
        }
    }

    @Test func daysKeepTheirTableAndUnknownModelsArePricedLater() throws {
        let (v1, v2) = try Self.tables()
        let scratch = try Scratch()
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("r1", "claude-opus-5-5", 100), ("r2", "gpt-6.1-sol-mini", 500)]))

        let (_, first, _) = try scratch.run([v1])
        #expect(first.count == 1)
        #expect(first[0].priceVersion == 1)
        #expect(first[0].cost?.unpricedRequests == 1, "v1 has no price for gpt-6.1-sol-mini")
        let opusUnderV1 = try #require(first[0].models.first { $0.model == "claude-opus-5-5" }?.cost?.costMicroUsd)

        let stored = HistoryDatabase.storedPricing(at: scratch.storePath)
        #expect(stored.bindings == ["2026-10-20": 1])
        #expect(stored.tables.keys.sorted() == [1], "a copy of every bound table is kept")

        let (unchanged, same, _) = try scratch.run([v1])
        #expect(unchanged.filesAnalyzed == 0)
        #expect(same == first)

        let (repriced, second, book) = try scratch.run([v1, v2])
        #expect(repriced.filesAnalyzed == 1, "a new table re-analyses files with unpriced responses")
        #expect(book.boundVersion(forDay: "2026-10-20") == 1, "the binding never changes")
        #expect(second[0].priceVersion == 1)
        #expect(second[0].cost?.unpricedRequests == 0)
        let models = Dictionary(uniqueKeysWithValues: second[0].models.map { ($0.model, $0.cost) })
        #expect(models["claude-opus-5-5"]??.costMicroUsd == opusUnderV1, "a known price never changes")
        #expect(models["gpt-6.1-sol-mini"]??.costMicroUsd == 3600, "late pricing with the current table")

        let (settled, _, _) = try scratch.run([v1, v2])
        #expect(settled.filesAnalyzed == 0)
    }

    @Test func aMissingTableCopyRebindsToTheCurrentTable() throws {
        let (v1, v2) = try Self.tables()
        let scratch = try Scratch()
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("r1", "claude-opus-5-5", 100)]))
        _ = try scratch.run([v2])
        let database = try HistoryDatabase(path: scratch.storePath)
        try database.savePriceBindings(["2026-10-19": 7]) { _ in nil }
        let book = PriceBook(tables: [v1, v2])
        _ = try HistoryAnalyzer(database: database, pricing: book)
        #expect(book.boundVersion(forDay: "2026-10-19") == 2)
        #expect(try database.priceBindings()["2026-10-19"] == 2, "the repaired binding is saved")
        #expect(try database.priceTables().keys.sorted() == [2])
    }

    @Test func contributionsWithoutCostDataStayUnavailableOrMakeTheDayPartial() {
        var old = DayAggregate()
        old.totals.requests = 2
        old.agents = 1
        var fresh = DayAggregate()
        fresh.add(
            ResponseRecord(key: "k", source: .codex, agentId: "a", model: "m", startMs: nil, endMs: 0, usage: TokenUsage(output: 1)),
            cost: 40
        )
        var onlyOld = DayAggregate()
        onlyOld.merge(old)
        #expect(onlyOld.cost == nil, "a day from an older store has no cost data")
        var mixed = DayAggregate()
        mixed.merge(old)
        mixed.merge(fresh)
        #expect(mixed.cost == CostTally(costMicroUsd: 40, unpricedRequests: 2), "its requests count as unpriced")
    }

    @Test func aVersionTwoStoreMigratesWithoutCostForGoneFiles() throws {
        let scratch = try Scratch()
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("r1", "claude-opus-5-5", 100)]))
        try FileManager.default.createDirectory(atPath: (scratch.storePath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: scratch.storePath, mode: .readWriteCreate)
        try old.execute("""
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, family TEXT NOT NULL, size INTEGER NOT NULL,
                modified INTEGER NOT NULL, version INTEGER NOT NULL, keys BLOB NOT NULL);
            CREATE TABLE contributions (file_id INTEGER NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL,
                requests INTEGER NOT NULL, input INTEGER NOT NULL, cached_input INTEGER NOT NULL,
                cache_write_input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
                measured_output INTEGER NOT NULL, measured_ms INTEGER NOT NULL, unfinalized INTEGER NOT NULL,
                agents INTEGER NOT NULL, PRIMARY KEY (file_id, day, source)) WITHOUT ROWID;
            CREATE TABLE contribution_models (file_id INTEGER NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL,
                model TEXT NOT NULL, requests INTEGER NOT NULL, output INTEGER NOT NULL, measured_output INTEGER NOT NULL,
                measured_ms INTEGER NOT NULL, PRIMARY KEY (file_id, day, source, model)) WITHOUT ROWID;
            CREATE TABLE day_peaks (day TEXT PRIMARY KEY, peak REAL NOT NULL) WITHOUT ROWID;
            INSERT INTO files VALUES (1, '\(scratch.directory.file("claude/p/gone.jsonl").path)', 'claude', 1, 1, 2, x'');
            INSERT INTO contributions VALUES (1, '2026-10-01', 'claudeCode', 2, 10, 0, 0, 30, 0, 30, 1000, 0, 1);
            INSERT INTO contribution_models VALUES (1, '2026-10-01', 'claudeCode', 'claude-opus-5-5', 2, 30, 30, 1000);
            PRAGMA user_version = 2;
            """)
        old.close()
        let (report, days, _) = try scratch.run([PriceBook.bundled])
        #expect(report.filesAnalyzed == 1)
        #expect(days.map(\.day) == ["2026-10-01", "2026-10-20"])
        #expect(days[0].cost == nil && days[0].priceVersion == nil, "no cost data for a day whose logs are gone")
        #expect(days[0].models.first?.cost == nil)
        #expect(days[1].cost.map { $0.costMicroUsd > 0 } == true)
        #expect(days[1].priceVersion == PriceBook.bundled.version)
    }

    // MARK: - Engine

    @Test func theEngineRepricesTodaysUnpricedResponsesWhenANewTableArrives() throws {
        let (v1, v2) = try Self.tables()
        let book = PriceBook(tables: [v1])
        var engine = SpeedEngine(pricing: book)
        let end: Int64 = 1_792_490_405_000
        let usage = TokenUsage(input: 5000, output: 500)
        engine.upsert(
            ResponseRecord(key: "a", source: .codex, agentId: "x", model: "gpt-6.1-sol-mini", startMs: end - 4000, endMs: end, usage: usage),
            project: "p", isCompletion: true, emitsEvents: false
        )
        let todayStart: Int64 = 1_792_454_400_000
        let before = engine.advance(nowMs: end + 1000, todayStartMs: todayStart, emitsEvents: false)
        #expect(before.todayCost == CostTally(costMicroUsd: 0, unpricedRequests: 1))
        #expect(before.todayCostByModel[.codex]?["gpt-6.1-sol-mini"]?.unpricedRequests == 1)
        book.add(v2)
        let after = engine.advance(nowMs: end + 1500, todayStartMs: todayStart, emitsEvents: false)
        #expect(after.todayCost == CostTally(costMicroUsd: 3600, unpricedRequests: 0))
        #expect(after.todayCostBySource[.codex] == CostTally(costMicroUsd: 3600, unpricedRequests: 0))
        #expect(after.liveCost.microUsdPerSecond > 0)
    }

    @Test func theEnginePricesWithTheDaysBoundTable() throws {
        let (v1, v2) = try Self.tables()
        // 2026-10-20 local (UTC here) was bound to v1 before; v2 is current.
        let book = PriceBook(tables: [v1, v2], bindings: ["2026-10-20": 1])
        var engine = SpeedEngine(pricing: book)
        let usage = TokenUsage(input: 1000, output: 100)
        let bound: Int64 = 1_792_490_405_000
        let next: Int64 = bound + 86_400_000
        for (key, end) in [("old", bound), ("new", next)] {
            engine.upsert(ResponseRecord(key: key, source: .claudeCode, agentId: "x", model: "claude-opus-5-5", startMs: end - 2000,
                                         endMs: end, usage: usage),
                          project: "p", isCompletion: true, emitsEvents: false)
        }
        let costs = Dictionary(uniqueKeysWithValues: engine.storedResponses.map { ($0.key, $0.costMicroUsd) })
        let labeler = DayLabeler(timeZone: .current)
        if labeler.label(for: Date(timeIntervalSince1970: TimeInterval(bound) / 1000)) == "2026-10-20" {
            #expect(costs["old"] == 7500, "a bound day keeps its table")
        }
        #expect(costs["new"] == 6000, "an unbound day binds to the current table")
        #expect(book.takeNewBindings().values.allSatisfy { $0 == 2 })
    }

    @Test func aResponseWithoutADateHasNoCost() throws {
        let (v1, v2) = try Self.tables()
        var engine = SpeedEngine(pricing: PriceBook(tables: [v1, v2]))
        let usage = TokenUsage(input: 1000, output: 100)
        // Year 0000 and past 9999-12-29 UTC: outside the calendar range of METRICS 8.
        for (key, end) in [("year0", Int64(-62_167_219_200_000)), ("far", Int64(253_402_387_139_999)), ("dated", Int64(1_792_490_405_000))] {
            engine.upsert(ResponseRecord(key: key, source: .claudeCode, agentId: "x", model: "claude-opus-5-5", startMs: end - 2000,
                                         endMs: end, usage: usage),
                          project: "p", isCompletion: true, emitsEvents: false)
        }
        let costs = Dictionary(uniqueKeysWithValues: engine.storedResponses.map { ($0.key, $0.costMicroUsd) })
        #expect(costs["year0"] == .some(nil))
        #expect(costs["far"] == .some(nil))
        #expect(costs["dated"] != .some(nil))
    }

    @Test func costReadingsHonourSubscriptionsAndPartialPrices() {
        func status(_ kind: SourceKind, live: Double, cost: Double, known: Double, today: CostTally, requests: Int) -> SourceStatus {
            SourceStatus(
                kind: kind, enabled: true, rootPath: "/r", available: true, sessionCount: 1, live: Rate(output: live, total: live),
                today: TokenTotals(requests: requests), activeAgents: 0,
                liveCost: LiveCost(microUsdPerSecond: cost, knownOutput: known), todayCost: today,
                unpricedModels: today.unpricedRequests > 0 ? ["mystery-\(kind.rawValue)"] : []
            )
        }
        var snapshot = SpeedSnapshot.empty
        snapshot.sources = [
            status(.codex, live: 100, cost: 2000, known: 100, today: CostTally(costMicroUsd: 9000), requests: 3),
            status(.claudeCode, live: 50, cost: 0, known: 0, today: CostTally(unpricedRequests: 2), requests: 2),
        ]
        let all = OrbSubset.cost(snapshot, sources: nil, billable: .everything)
        #expect(all.microUsdPerSecond == 2000)
        #expect(abs(all.knownShare - 100.0 / 150.0) < 1e-12)
        #expect(all.state == .partial)
        #expect(all.today == CostTally(costMicroUsd: 9000, unpricedRequests: 2))
        #expect(all.unpricedModels == ["mystery-claudeCode"])

        let claudeOnly = OrbSubset.cost(snapshot, sources: SourceSet(.claudeCode), billable: .everything)
        #expect(claudeOnly.state == .nothingPriced)

        let billableCodex = OrbSubset.cost(snapshot, sources: nil, billable: SourceSet(.codex))
        #expect(billableCodex.state == .priced)
        #expect(billableCodex.excluded == [.claudeCode])

        let subscriptionOnly = OrbSubset.cost(snapshot, sources: SourceSet(.claudeCode), billable: SourceSet(.codex))
        #expect(subscriptionOnly.state == .subscriptionOnly)
        #expect(subscriptionOnly.microUsdPerSecond == 0)
    }
}
