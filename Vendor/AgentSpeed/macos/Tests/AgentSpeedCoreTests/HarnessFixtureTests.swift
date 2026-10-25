import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Harness fixtures")
struct HarnessFixtureTests {
    static let dayStart: Int64 = 1_792_454_400_000
    static let now: Int64 = 1_792_497_700_000

    static func expected(_ source: String) throws -> [String: Any] {
        try #require(try Fixtures.json("harness-expected.json")[source] as? [String: Any])
    }

    static func compare(_ records: [ResponseRecord], _ expected: [[String: Any]]) throws {
        #expect(records.map(\.key) == expected.compactMap { $0.string("key") })
        for (record, wanted) in zip(records, expected) {
            #expect(record.startMs == wanted.int64("startMs"), "\(record.key) start")
            #expect(record.endMs == wanted.int64("endMs"), "\(record.key) end")
            #expect(record.usage.input == wanted.int("input"), "\(record.key) input")
            #expect(record.usage.output == wanted.int("output"), "\(record.key) output")
            #expect(record.usage.cachedInput == wanted.int("cachedInput"), "\(record.key) cached")
            #expect(record.usage.cacheWriteInput == wanted.int("cacheWriteInput"), "\(record.key) cache write")
            #expect(record.usage.reasoning == wanted.int("reasoning"), "\(record.key) reasoning")
            #expect(record.model == wanted.string("model"), "\(record.key) model")
            #expect(record.isFinal == wanted["final"] as? Bool, "\(record.key) final")
            #expect(record.requestCount == (wanted.int64("requestCount").map(Int.init) ?? 1), "\(record.key) requests")
            expectPricingFields(record, wanted, record.key)
        }
    }

    @Test func sourceOrdinalsAndProtocolIdsStayStable() {
        #expect(Array(SourceKind.allCases.prefix(10)).map(\.rawValue) == ["codex", "claudeCode", "claudeDesktop", "deepseek", "opencode", "gemini", "omp", "antigravity", "workbuddy", "workbuddyAi"])
        #expect(SourceSet(.zcode).rawValue == 1 << 10)
        #expect(SourceSet(.kimi).rawValue == 1 << 11)
        #expect(SourceSet(.grokBuild).rawValue == 1 << 12)
    }

    @Test func zcodeCanonicalUsageAndParentSessions() throws {
        let expected = try Self.expected("zcode")
        let path = Fixtures.root.appendingPathComponent(try #require(expected.string("database"))).path
        let source = ZcodeSource(root: path, fileID: -2)
        #expect(source.refreshAvailability() && source.isReady)
        var deduper = Deduper()
        let update = source.seed(todayStartMs: Self.dayStart, deduper: &deduper)
        for wanted in try #require(expected["sessions"] as? [[String: Any]]) {
            let id = path + "#" + (try #require(wanted.string("id")))
            let state = try #require(update.agents[id])
            #expect(state.project == wanted.string("project"))
            #expect(source.parentLinks[id] == wanted.string("parentId").map { path + "#" + $0 })
            let records = update.upserts.map(\.0.record).filter { $0.agentId == id }
            try Self.compare(records, try #require(wanted["responses"] as? [[String: Any]]))
        }
        #expect(update.agents.values.contains { $0.phase == .generating })
        #expect(source.refreshIfChanged(deduper: &deduper) == nil)
    }

    @Test func kimiWireVariantsAndSharedDeduplication() throws {
        let expected = try Self.expected("kimi")
        var deduper = Deduper()
        for (index, wanted) in try #require(expected["files"] as? [[String: Any]]).enumerated() {
            let path = Fixtures.root.appendingPathComponent(try #require(wanted.string("path")))
            var parser = KimiParser(agentId: path.path, fileID: FileID(index))
            var records: [String: ResponseRecord] = [:]
            var order: [String] = []
            forEachLine(in: try Data(contentsOf: path)) { bytes in
                parser.consume(KimiLineExtractor.extract(bytes), deduper: &deduper) { upsert in
                    if records[upsert.record.key] == nil { order.append(upsert.record.key) }
                    records[upsert.record.key] = upsert.record
                }
            }
            try Self.compare(order.compactMap { records[$0] }, try #require(wanted["responses"] as? [[String: Any]]))
            #expect(parser.state.project == wanted.string("project"))
            #expect(parser.state.isSubagent == wanted["isSubagent"] as? Bool)
            #expect(parser.state.thread?.parentId == wanted.string("parentFile").map { Fixtures.root.appendingPathComponent($0).path })
        }
    }

    @Test func grokNativeBatchesSuppressSubagentsAndDeduplicateForks() throws {
        let expected = try Self.expected("grok")
        var deduper = Deduper()
        for (index, wanted) in try #require(expected["files"] as? [[String: Any]]).enumerated() {
            let path = Fixtures.root.appendingPathComponent(try #require(wanted.string("path")))
            var parser = GrokBuildParser(agentId: path.path, fileID: FileID(index))
            var records: [String: ResponseRecord] = [:]
            var order: [String] = []
            forEachLine(in: try Data(contentsOf: path)) { bytes in
                parser.consume(GrokBuildLine.extract(bytes), deduper: &deduper) { upsert in
                    if records[upsert.record.key] == nil { order.append(upsert.record.key) }
                    records[upsert.record.key] = upsert.record
                }
            }
            try Self.compare(order.compactMap { records[$0] }, try #require(wanted["responses"] as? [[String: Any]]))
            #expect(parser.state.project == wanted.string("project"))
            #expect(parser.state.isSubagent == wanted["isSubagent"] as? Bool)
            #expect(parser.state.thread?.parentId == wanted.string("parentFile").map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent })
        }
    }

    @Test func batchRequestCountsFlowThroughTotalsCostsHistoryAndReports() {
        var record = ResponseRecord(key: "grok:batch:custom", source: .grokBuild, agentId: "batch", model: "custom",
                                    startMs: Self.now - 6000, endMs: Self.now, usage: TokenUsage(input: 1000, output: 300), requestCount: 2)
        var ledger = DayLedger(dayStartMs: Self.dayStart)
        ledger.replace(nil, with: record)
        #expect(ledger.totals.requests == 2 && ledger.cost.unpricedRequests == 2)
        #expect(ledger.average == 50)
        var history = DayAggregate()
        history.add(record, cost: nil)
        #expect(history.totals.requests == 2 && history.models["custom"]?.requests == 2)
        #expect(history.cost?.unpricedRequests == 2 && history.models["custom"]?.cost?.unpricedRequests == 2)
        var reports = ReportLedger()
        reports.count(record, modelId: "unknown")
        #expect(reports.counters.total.requests == 2 && reports.counters.total.unpricedRequests == 2)
        let old = record
        record.requestCount = 3
        record.usage.output = 360
        ledger.replace(old, with: record)
        reports.grow(record, modelId: "unknown")
        #expect(ledger.totals.requests == 3 && ledger.cost.unpricedRequests == 3 && ledger.average == 60)
        #expect(reports.counters.total.requests == 3 && reports.counters.total.unpricedRequests == 3)
        #expect(reports.counters.total.output == 360)
    }

    static func configuration() -> MonitorConfiguration {
        MonitorConfiguration(enabledSources: [.zcode, .kimi, .grokBuild], zcodeRoot: Fixtures.root.appendingPathComponent("zcode/cli/db"),
                             kimiRoot: Fixtures.root.appendingPathComponent("kimi/sessions"),
                             grokBuildRoot: Fixtures.root.appendingPathComponent("grok/sessions"))
    }

    @Test func liveAndHistoryShareExistingMathAndRestartDoesNotAccumulate() throws {
        let configuration = Self.configuration()
        let session = TranscriptSession(configuration: configuration, clock: { Self.now })
        #expect(session.hasAvailableRoot)
        _ = session.seed(todayStartMs: Self.dayStart)
        let (output, _) = session.advance(nowMs: Self.now, todayStartMs: Self.dayStart, emitsEvents: false)
        #expect(output.todayBySource[.zcode]?.requests == 4)
        #expect(output.todayBySource[.zcode]?.input == 3680 && output.todayBySource[.zcode]?.output == 470)
        #expect(output.todayBySource[.kimi]?.requests == 4)
        #expect(output.todayBySource[.kimi]?.input == 560 && output.todayBySource[.kimi]?.output == 305)
        #expect(output.todayBySource[.grokBuild]?.requests == 4 && output.todayBySource[.grokBuild]?.output == 700)
        #expect(output.today.requests == 12 && output.today.output == 1475)
        let context = SnapshotContext(session: session, todayStartMs: Self.dayStart)
        #expect(context.sources[.zcode]?.sessionCount == 2)
        #expect(context.sources[.kimi]?.sessionCount == 2)
        #expect(context.sources[.grokBuild]?.sessionCount == 2)
        let directory = try TempDirectory()
        let store = directory.file("history.sqlite").path
        let first = try HistoryScan.run(configuration: configuration, timeZone: TimeZone(secondsFromGMT: 0)!, storePath: store)
        let second = try HistoryScan.run(configuration: configuration, timeZone: TimeZone(secondsFromGMT: 0)!, storePath: store)
        #expect(first.days == second.days)
        #expect(second.filesAnalyzed == 0 && second.sessionsAnalyzed == 0)
        let zcode = try #require(first.days.first { $0.source == .zcode })
        let kimi = try #require(first.days.first { $0.source == .kimi })
        #expect(zcode.totals == output.todayBySource[.zcode])
        #expect(kimi.totals == output.todayBySource[.kimi])
        #expect(zcode.measuredMs == 9500 && kimi.measuredMs == 12_200)
        let grok = try #require(first.days.first { $0.source == .grokBuild })
        #expect(grok.totals == output.todayBySource[.grokBuild] && grok.measuredMs == 11_000)
    }

    @Test func zcodeWALFinalizationEmitsOneCompletion() throws {
        let directory = try TempDirectory()
        let path = directory.file("db.sqlite")
        try FileManager.default.copyItem(at: Fixtures.root.appendingPathComponent("zcode/cli/db/db.sqlite"), to: path)
        let writer = try SQLiteConnection(path: path.path, mode: .readWriteCreate)
        try writer.execute("PRAGMA journal_mode=WAL")
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.zcode], zcodeRoot: directory.url),
                                        clock: { 1_792_497_670_000 })
        _ = session.seed(todayStartMs: Self.dayStart)
        let running = try #require(session.zcode)
        #expect(running.isReady)
        try writer.execute("UPDATE model_usage SET status='completed',completed_at=1792497669000,input_tokens=300,output_tokens=70 WHERE status='running'")
        #expect(session.pollRecentFiles(nowMs: 1_792_497_670_000))
        let (output, events) = session.advance(nowMs: 1_792_497_670_000, todayStartMs: Self.dayStart, emitsEvents: true)
        #expect(output.today.requests == 5 && output.today.output == 540)
        #expect(events.filter { if case .responseCompleted = $0 { true } else { false } }.count == 1)
        #expect(!session.pollRecentFiles(nowMs: Self.now))
    }

    @Test func zcodeMessageAndToolPhasesDoNotInventUsage() throws {
        let directory = try TempDirectory()
        let path = directory.file("db.sqlite")
        try FileManager.default.copyItem(at: Fixtures.root.appendingPathComponent("zcode/cli/db/db.sqlite"), to: path)
        let writer = try SQLiteConnection(path: path.path, mode: .readWriteCreate)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES('user-live','sess-z-main',1792497640000,1792497640000,'{\"role\":\"user\",\"time\":{\"created\":1792497640000}}')")
        let configuration = MonitorConfiguration(enabledSources: [.zcode], zcodeRoot: directory.url)
        let session = TranscriptSession(configuration: configuration, clock: { Self.now })
        _ = session.seed(todayStartMs: Self.dayStart)
        func phase() -> AgentPhase? {
            session.advance(nowMs: 1_792_497_645_500, todayStartMs: Self.dayStart, emitsEvents: false).output.agents
                .first { $0.agent.id.hasSuffix("#sess-z-main") }?.phase
        }
        #expect(phase() == .generating)
        try writer.execute("INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES('assistant-live','sess-z-main',1792497645000,1792497645000,'{\"role\":\"assistant\",\"modelID\":\"glm-5.3\",\"time\":{\"created\":1792497645000}}')")
        try writer.execute("INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES('tool-live','assistant-live','sess-z-main',1792497645000,1792497645000,'{\"type\":\"tool\",\"state\":{\"status\":\"running\"}}')")
        #expect(session.pollRecentFiles(nowMs: Self.now))
        #expect(phase() == .tools)
        #expect(session.responses.count == 4)
        try writer.execute("UPDATE part SET data='{\"type\":\"tool\",\"state\":{\"status\":\"completed\"}}' WHERE id='tool-live'")
        try writer.execute("UPDATE message SET data='{\"role\":\"assistant\",\"time\":{\"created\":1792497645000,\"completed\":1792497645500}}' WHERE id='assistant-live'")
        #expect(session.pollRecentFiles(nowMs: Self.now))
        #expect(phase() == .idle && session.responses.count == 4)
    }

    @Test func unsupportedDatabaseReportsWarningWithoutWriting() throws {
        let directory = try TempDirectory()
        do {
            let writer = try SQLiteConnection(path: directory.file("db.sqlite").path, mode: .readWriteCreate)
            try writer.execute("CREATE TABLE unrelated(id TEXT)")
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.zcode], zcodeRoot: directory.url))
        #expect(!session.hasAvailableRoot && session.unsupportedSources == [.zcode])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    }

    @Test func customRootsRescanAndDetectDatabasesCreatedLater() throws {
        let directory = try TempDirectory()
        let root = directory.file("custom-zcode")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = MonitorConfiguration(enabledSources: [.zcode], zcodeRoot: root)
        let session = TranscriptSession(configuration: configuration)
        #expect(!session.hasAvailableRoot)
        let database = root.appendingPathComponent("cli/db/db.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.root.appendingPathComponent("zcode/cli/db/db.sqlite"), to: database)
        #expect(session.rediscover(todayStartMs: Self.dayStart) && session.hasAvailableRoot)
        #expect(session.responses.count == 4)
        var moved = configuration
        moved.zcodeRoot = directory.file("other")
        #expect(moved.requiresRescan(comparedTo: configuration))
        moved = configuration
        moved.kimiRoot = directory.file("custom-kimi")
        #expect(moved.requiresRescan(comparedTo: configuration))
        #expect(TranscriptNames.kimiSession.accepts(relativeComponents: ["work", "sid", "agents", "main", "wire.jsonl"]))
        #expect(!TranscriptNames.kimiSession.accepts(relativeComponents: ["work", "sid", "tools", "wire.jsonl"]))
        #expect(!TranscriptNames.kimiSession.accepts(relativeComponents: ["work", "sid", "wire.jsonl"]))
        #expect(!TranscriptNames.kimiSession.acceptsFiles(inDirectoryAtDepth: 2))
    }

    @Test func malformedAndHostileKimiFieldsStayBounded() {
        var parser = KimiParser(agentId: "/sessions/work/sid/agents/main/wire.jsonl", fileID: 0)
        var deduper = Deduper()
        var records: [ResponseRecord] = []
        let input = """
        {broken}
        {"type":"context.append_message","time":9223372036854775807,"message":{"role":"assistant","id":"huge-time","usage":{"inputOther":1,"output":1}}}
        {"type":"context.append_message","time":1792497634000,"message":{"role":"assistant","id":"clamped","usage":{"inputOther":-1,"inputCacheRead":2,"inputCacheCreation":3,"output":2000000000000}}}

        """
        forEachLine(in: Data(input.utf8)) { bytes in
            parser.consume(KimiLineExtractor.extract(bytes), deduper: &deduper) { records.append($0.record) }
        }
        #expect(parser.state.malformedLines == 1)
        #expect(records.count == 1 && records.first?.key == "kimi:clamped")
        #expect(records.first?.usage.input == 5 && records.first?.usage.output == 1_000_000_000_000)
        #expect(records.first?.startMs == nil)
    }

    @Test func processClassificationUsesHarnessInsteadOfModel() {
        let rules = AgentProcessRules(platform: TrafficPlatform(kind: .macos, home: "/Users/dev"))
        #expect(rules.source(executable: "/usr/local/bin/zcode", arguments: { [] }, ancestorExecutables: []) == .zcode)
        #expect(rules.source(executable: "/usr/local/bin/kimi", arguments: { [] }, ancestorExecutables: []) == .kimi)
        #expect(rules.source(executable: "/usr/local/bin/codex", arguments: { ["codex", "--model", "deepseek"] }, ancestorExecutables: []) == .codex)
    }
}
