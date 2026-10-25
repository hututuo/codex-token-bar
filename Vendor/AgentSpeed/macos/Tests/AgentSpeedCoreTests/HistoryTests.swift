import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Daily history")
struct HistoryTests {
    static let utc = TimeZone(identifier: "UTC")!

    /// The fixtures folder as every source's data; `omp` plays `~/.omp` and `antigravity` plays `~/.gemini`, so their
    /// automatic roots (every profile, the three stores) are used; `workbuddy` plays `~` of both WorkBuddy editions.
    static func configuration(fixtures root: URL) -> MonitorConfiguration {
        var configuration = MonitorConfiguration(
            enabledSources: Set(SourceKind.allCases.prefix(10)),
            codexRoot: root.appendingPathComponent("codex/sessions", isDirectory: true),
            claudeRoot: root.appendingPathComponent("claude/projects", isDirectory: true),
            dshRoot: root.appendingPathComponent("dsh/sessions", isDirectory: true),
            opencodeRoot: root.appendingPathComponent("opencode/opencode.db"),
            geminiRoot: root.appendingPathComponent("gemini/tmp", isDirectory: true),
            workbuddyRoot: root.appendingPathComponent("workbuddy/.workbuddy", isDirectory: true),
            workbuddyAiRoot: root.appendingPathComponent("workbuddy/.workbuddy-ai", isDirectory: true)
        )
        configuration.automaticRoots = [
            .omp: TranscriptLocations.ompRoots(environment: ["PI_CONFIG_DIR": "omp"], home: root),
            .antigravity: ["antigravity-cli", "antigravity", "antigravity-ide"].map {
                root.appendingPathComponent("antigravity", isDirectory: true).appendingPathComponent($0, isDirectory: true)
            },
        ]
        return configuration
    }

    static var fixtureConfiguration: MonitorConfiguration { configuration(fixtures: Fixtures.root) }

    /// A copy of the fixtures whose modification times follow `parser-expected.json` `mtimes` (git does not keep them).
    static func fixtureCopy() throws -> (TempDirectory, URL) {
        let directory = try TempDirectory()
        let copy = directory.file("fixtures")
        try FileManager.default.copyItem(at: Fixtures.root, to: copy)
        let mtimes = try Fixtures.json("parser-expected.json")["mtimes"] as? [String: NSNumber] ?? [:]
        for (relative, ms) in mtimes {
            let date = Date(timeIntervalSince1970: ms.doubleValue / 1000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.appendingPathComponent(relative).path)
        }
        return (directory, copy)
    }

    /// The JSON shape of `reference.py --dump-history`.
    static func json(_ day: DailyUsage) -> [String: Any] {
        func null(_ value: Any?) -> Any { value ?? NSNull() }
        var models: [String: Any] = [:]
        for model in day.models {
            models[model.model] = [
                "requests": model.requests, "output": model.output, "measuredOutput": model.measuredOutput,
                "measuredMs": model.measuredMs, "costMicroUsd": null(model.cost?.costMicroUsd),
                "unpricedRequests": null(model.cost?.unpricedRequests),
            ]
        }
        return [
            "date": day.day, "source": day.source.rawValue, "requests": day.totals.requests, "input": day.totals.input,
            "cachedInput": day.totals.cachedInput, "cacheWriteInput": day.totals.cacheWriteInput,
            "output": day.totals.output, "reasoning": day.totals.reasoning, "measuredOutput": day.measuredOutput,
            "measuredMs": day.measuredMs, "unfinalized": day.unfinalized, "costMicroUsd": null(day.cost?.costMicroUsd),
            "unpricedRequests": null(day.cost?.unpricedRequests), "priceVersion": null(day.priceVersion),
            "agents": day.agents, "models": models,
        ]
    }

    /// The fixture price tables and stored bindings of `history-expected.json` `prices` (METRICS 9.7).
    static func fixturePricing() throws -> PriceBook {
        let prices = try #require(try Fixtures.json("history-expected.json")["prices"] as? [String: Any])
        let tables = try #require(prices["tables"] as? [String]).map { try PriceTableTests.table($0) }
        let bindings = (prices["bindings"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
        return PriceBook(tables: tables, bindings: bindings)
    }

    @Test func fixturesMatchExpectedHistory() throws {
        let expected = try #require(try Fixtures.json("history-expected.json")["days"] as? [[String: Any]])
        #expect(Set(expected.compactMap { $0["source"] as? String }) == Set(Self.fixtureConfiguration.enabledSources.map(\.rawValue)))
        let (directory, copy) = try Self.fixtureCopy()
        let report = try HistoryScan.run(
            configuration: Self.configuration(fixtures: copy), timeZone: Self.utc, pricing: try Self.fixturePricing()
        )
        #expect(report.days.count == expected.count)
        for (day, want) in zip(report.days, expected) {
            let got = Self.json(day) as NSDictionary
            #expect(got.isEqual(to: want), "\(day.day) \(day.source.rawValue): \(got) != \(want)")
        }
        let parserExpected = try Fixtures.json("parser-expected.json")
        let files = try #require(parserExpected["order"] as? [String]).count
        let databases = try #require((parserExpected["antigravity"] as? [String: Any])?["order"] as? [String]).count
        #expect(report.filesAnalyzed == files + databases)
        #expect(report.sessionsAnalyzed == 2)
        #expect(report.days.allSatisfy { $0.peak == nil })
        _ = directory
    }

    @Test func keyHashIsFNV1a() {
        #expect(KeyHash.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(KeyHash.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(KeyHash.fnv1a("foobar") == 0x85944171F73967E8)
    }

    @Test func dayLabelsFollowTheTimeZone() {
        var utc = DayLabeler(timeZone: Self.utc)
        var tokyo = DayLabeler(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let lateUTC: Int64 = 1_792_540_799_999 // 2026-10-20T23:59:59.999Z
        #expect(utc.label(forMs: lateUTC) == "2026-10-20")
        #expect(utc.label(forMs: lateUTC + 1) == "2026-10-21")
        #expect(utc.label(forMs: lateUTC) == "2026-10-20")
        #expect(tokyo.label(forMs: lateUTC) == "2026-10-21")
    }

    // MARK: - Store

    /// A Claude transcript with one response per `(id, output)` pair, ending at `base + index` seconds.
    static func claude(_ responses: [(String, Int)], base: Int64 = 1_792_490_400) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for (index, (id, output)) in responses.enumerated() {
            let start = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(base + Int64(index) * 10)))
            let end = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(base + Int64(index) * 10 + 4)))
            lines.append(#"{"type":"user","cwd":"/w/p","message":{"role":"user","content":"q"},"timestamp":"\#(start)"}"#)
            lines.append(#"{"type":"assistant","cwd":"/w/p","message":{"id":"\#(id)","model":"m","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":\#(output)}},"timestamp":"\#(end)"}"#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct Scratch {
        let directory: TempDirectory
        var configuration: MonitorConfiguration
        var storePath: String

        init() throws {
            directory = try TempDirectory()
            configuration = MonitorConfiguration(
                enabledSources: [.claudeCode, .claudeDesktop],
                claudeRoot: directory.file("claude"),
                opencodeRoot: directory.file("opencode")
            )
            storePath = directory.file("store/history.sqlite").path
        }

        /// A fresh analyzer over the same store, like a new launch.
        func run(version: Int64 = HistoryAnalyzer.analysisVersion) throws -> (HistoryAnalyzer.Report, [DailyUsage]) {
            let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: storePath))
            var options = HistoryAnalyzer.Options(timeZone: HistoryTests.utc)
            options.analysisVersion = version
            let report = try analyzer.run(configuration: configuration, options: options)
            return (report, analyzer.days(sources: configuration.enabledSources))
        }
    }

    @Test func storeReusesUnchangedFilesAndKeepsDeletedOnes() throws {
        let scratch = try Scratch()
        let old = Date(timeIntervalSince1970: 1_792_490_000)
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("m1", 100), ("m2", 50)]), modified: old)
        try scratch.directory.write("claude/p/b.jsonl", Self.claude([("m3", 7)], base: 1_792_600_000), modified: old.addingTimeInterval(1))
        // A resumed session copies m1: it stays owned by a.jsonl, which comes first in startup order.
        try scratch.directory.write("claude/p/c.jsonl", Self.claude([("m1", 100), ("m4", 1)]), modified: old.addingTimeInterval(2))

        let (first, days) = try scratch.run()
        #expect(first.filesAnalyzed == 3)
        #expect(days.map(\.day) == ["2026-10-20", "2026-10-21"])
        #expect(days[0].totals.requests == 3)
        #expect(days[0].totals.output == 151)
        #expect(days[0].agents == 2)
        #expect(days[0].models == [ModelUsage(model: "m", requests: 3, output: 151, measuredOutput: 151, measuredMs: 12_000,
                                              cost: CostTally(unpricedRequests: 3))])
        #expect(days[0].cost == CostTally(unpricedRequests: 3), "model m has no price")
        #expect(days[0].measuredMs == 12_000)
        #expect(days[1].totals.output == 7)

        let (second, sameDays) = try scratch.run()
        #expect(second.filesAnalyzed == 0, "unchanged files are skipped by identity")
        #expect(sameDays == days)

        try scratch.directory.append("claude/p/c.jsonl", Self.claude([("m5", 1000)], base: 1_792_490_500))
        let (third, changedDays) = try scratch.run()
        #expect(third.filesAnalyzed == 1)
        #expect(changedDays[0].totals.output == 1151)
        #expect(changedDays[0].totals.requests == 4)

        try FileManager.default.removeItem(at: scratch.directory.file("claude/p/b.jsonl"))
        let (fourth, keptDays) = try scratch.run()
        #expect(fourth.filesAnalyzed == 0)
        #expect(keptDays == changedDays, "a deleted file keeps its contributions")

        let (bumped, recomputed) = try scratch.run(version: HistoryAnalyzer.analysisVersion + 1)
        #expect(bumped.filesAnalyzed == 2, "a version bump re-analyses every existing file")
        #expect(recomputed == changedDays, "and keeps the days that have no logs any more")
        let (afterBump, _) = try scratch.run(version: HistoryAnalyzer.analysisVersion + 1)
        #expect(afterBump.filesAnalyzed == 0)

        HistoryDatabase.delete(at: scratch.storePath)
        let (cleared, fresh) = try scratch.run()
        #expect(cleared.filesAnalyzed == 2)
        #expect(fresh.map(\.day) == ["2026-10-20"], "clearing forgets days without logs")
        #expect(fresh[0].totals.output == 1151)
    }

    @Test func aVersionOneStoreMigratesAndRecomputesModelSpeeds() throws {
        let scratch = try Scratch()
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("m1", 100), ("m2", 50)]))
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
                model TEXT NOT NULL, requests INTEGER NOT NULL, output INTEGER NOT NULL,
                PRIMARY KEY (file_id, day, source, model)) WITHOUT ROWID;
            CREATE TABLE day_peaks (day TEXT PRIMARY KEY, peak REAL NOT NULL) WITHOUT ROWID;
            INSERT INTO files VALUES (1, '\(scratch.directory.file("claude/p/gone.jsonl").path)', 'claude', 1, 1, 1, x'');
            INSERT INTO contributions VALUES (1, '2026-10-01', 'claudeCode', 2, 10, 0, 0, 30, 0, 30, 1000, 0, 1);
            INSERT INTO contribution_models VALUES (1, '2026-10-01', 'claudeCode', 'm', 2, 30);
            PRAGMA user_version = 1;
            """)
        old.close()

        let (report, days) = try scratch.run()
        #expect(report.filesAnalyzed == 1)
        #expect(days.map(\.day) == ["2026-10-01", "2026-10-20"], "a day without logs any more is kept")
        #expect(days[0].models == [ModelUsage(model: "m", requests: 2, output: 30)], "its model speed stays unknown")
        #expect(days[0].cost == nil, "and it has no cost data")
        #expect(days[1].models == [ModelUsage(model: "m", requests: 2, output: 150, measuredOutput: 150, measuredMs: 8000,
                                              cost: CostTally(unpricedRequests: 2))])
        #expect(days[1].models.first?.averageSpeed == 150 / 8.0)
        #expect(try scratch.run().0.filesAnalyzed == 0)
    }

    @Test func changedFileDoesNotStealKeysOwnedByOthers() throws {
        let scratch = try Scratch()
        let old = Date(timeIntervalSince1970: 1_792_490_000)
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("k1", 10)]), modified: old)
        try scratch.directory.write("claude/p/b.jsonl", Self.claude([("k2", 20)]), modified: old.addingTimeInterval(1))
        _ = try scratch.run()
        // b now also contains a copy of k1; a still owns it.
        try scratch.directory.write("claude/p/b.jsonl", Self.claude([("k2", 20), ("k1", 10)]), modified: old.addingTimeInterval(5))
        let (report, days) = try scratch.run()
        #expect(report.filesAnalyzed == 1)
        #expect(days.first?.totals.requests == 2)
        #expect(days.first?.totals.output == 30)
    }

    @Test func progressCoversEveryFile() throws {
        let scratch = try Scratch()
        for index in 0..<5 {
            try scratch.directory.write("claude/p/f\(index).jsonl", Self.claude([("p\(index)", 10)]))
        }
        let analyzer = try HistoryAnalyzer(database: HistoryDatabase.inMemory())
        var seen: [HistoryAnalyzer.Progress] = []
        try analyzer.run(configuration: scratch.configuration, options: HistoryAnalyzer.Options(timeZone: Self.utc),
                         progress: { seen.append($0) })
        #expect(seen.first?.filesDone == 0)
        #expect(seen.last?.filesDone == 5)
        #expect(seen.last?.filesTotal == 5)
        #expect(seen.last?.fraction == 1)
        #expect(seen.map(\.filesDone) == seen.map(\.filesDone).sorted())
    }

    @Test func peaksAreStoredPerDay() throws {
        let scratch = try Scratch()
        try scratch.directory.write("claude/p/a.jsonl", Self.claude([("m1", 100)]))
        let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: scratch.storePath))
        try analyzer.run(configuration: scratch.configuration, options: HistoryAnalyzer.Options(timeZone: Self.utc))
        #expect(try analyzer.recordPeak(42, day: "2026-10-20"))
        #expect(try !analyzer.recordPeak(40, day: "2026-10-20"))
        let reopened = try HistoryAnalyzer(database: HistoryDatabase(path: scratch.storePath))
        #expect(reopened.days(sources: [.claudeCode]).first?.peak == 42)
    }

    @Test func archivedCodexSessionsAreIncluded() throws {
        let directory = try TempDirectory()
        let line = #"{"timestamp":"2026-10-20T10:00:00.000Z","type":"session_meta","payload":{"id":"t1","cwd":"/w/x"}}"#
            + "\n" + #"{"timestamp":"2026-10-20T10:00:05.000Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":5,"output_tokens":9}}}"#
            + "\n"
        try directory.write("codex/archived_sessions/rollout-a.jsonl", line)
        try FileManager.default.createDirectory(at: directory.file("codex/sessions"), withIntermediateDirectories: true)
        let report = try HistoryScan.run(
            configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.file("codex/sessions")),
            timeZone: Self.utc
        )
        #expect(report.days.map(\.totals.output) == [9])
    }
}

@MainActor
@Suite("History service", .serialized)
struct HistoryServiceTests {
    @Test func publishesProgressThenReadyAndClears() async throws {
        let directory = try TempDirectory()
        let store = HistoryStore()
        let storeURL = directory.file("Application Support/AgentSpeed/history.sqlite")
        let service = HistoryService(store: store, configuration: HistoryTests.fixtureConfiguration, storeURL: storeURL)
        service.start()
        defer { service.stop() }

        let ready = await LiveMonitorTests.waitUntil {
            if case .ready = store.state { return true }
            return false
        }
        #expect(ready)
        #expect(!store.days.isEmpty)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        let expectedOutput = store.days.reduce(0) { $0 + $1.totals.output }

        store.clear()
        let cleared = await LiveMonitorTests.waitUntil {
            if case .ready(let at) = store.state, Date().timeIntervalSince(at) < 5,
               store.days.reduce(0, { $0 + $1.totals.output }) == expectedOutput { return true }
            return false
        }
        #expect(cleared)

        var configuration = HistoryTests.fixtureConfiguration
        configuration.enabledSources = [.opencode]
        service.update(configuration: configuration)
        #expect(await LiveMonitorTests.waitUntil { !store.days.isEmpty && store.days.allSatisfy { $0.source == .opencode } })
    }

    @Test func recordsTheLivePeakOfTheDay() async throws {
        let directory = try TempDirectory()
        let store = HistoryStore()
        let live = SpeedStore()
        let service = HistoryService(store: store, configuration: HistoryTests.fixtureConfiguration, liveStore: live,
                                     storeURL: directory.file("history.sqlite"))
        service.start()
        defer { service.stop() }
        #expect(await LiveMonitorTests.waitUntil { if case .ready = store.state { true } else { false } })
        let day = try #require(store.days.first?.day)
        let noon = try #require(DayLabeler(timeZone: .current).calendar.date(from: DateComponents(
            year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)), day: Int(day.suffix(2)), hour: 12)))
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        snapshot.timestamp = noon
        snapshot.peakToday = Rate(output: 321, total: 900)
        live.publishLive(snapshot)
        service.samplePeak()
        #expect(await LiveMonitorTests.waitUntil { store.days.filter { $0.day == day }.allSatisfy { $0.peak == 321 } })
        #expect(store.days.filter { $0.day != day }.allSatisfy { $0.peak == nil })
    }
}
