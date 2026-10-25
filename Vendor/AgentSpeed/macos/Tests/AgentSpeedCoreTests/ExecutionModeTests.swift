import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Execution modes")
struct ExecutionModeTests {
    @Test func sharedNormalizationAndAttribution() throws {
        let root = try Fixtures.json("execution-mode-cases.json")
        for item in try #require(root["normalization"] as? [[String: Any]]) {
            let evidence = try #require(item.string("evidence").flatMap(ExecutionModeEvidence.init(rawValue:)))
            let scope = try #require(item.string("scope").flatMap(ExecutionModeScope.init(rawValue:)))
            let got = ExecutionModeAdapters.normalize(adapter: item.string("adapter") ?? "", raw: item.string("rawValue"),
                                                       provider: item.string("provider"), evidence: evidence, scope: scope)
            let expected = item["expected"] as? [String: Any]
            if let expected {
                let bytes = try JSONSerialization.data(withJSONObject: expected)
                let wanted = try JSONDecoder().decode(ExecutionModeFact.self, from: bytes)
                #expect(got == wanted, "\(item.string("id") ?? "")")
            } else { #expect(got == nil, "\(item.string("id") ?? "")") }
        }
        for item in try #require(root["attribution"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: try #require(item["facts"]))
            let facts = try JSONDecoder().decode([ExecutionModeFact].self, from: bytes)
            let kind = try #require(item.string("kind").flatMap(ExecutionModeKind.init(rawValue:)))
            let expected = try #require(item["expected"] as? [String: Any])
            let result = ExecutionModes(facts).attribution(for: kind)
            #expect(result.mode == expected.string("mode"), "\(item.string("id") ?? "")")
            #expect(result.evidence == expected.string("evidence"))
            #expect(result.provider == expected.string("provider"))
        }
    }

    @Test func boundedFactsAndAmbiguousProviders() throws {
        let bad = #"{"kind":"serviceTier","value":"fast","rawValue":"fast","evidence":"served","scope":"response","provider":"https://secret.invalid"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ExecutionModeFact.self, from: Data(bad.utf8)) }
        var facts = ExecutionModes()
        for index in 0..<30 {
            facts.insert(try #require(ExecutionModeFact(kind: .serviceTier, rawValue: "fast", evidence: .selected,
                                                       provider: "p\(index)", scope: .request)))
        }
        #expect(facts.facts.count == 20)
        #expect(facts.attribution(for: .serviceTier).isUnknown)
        #expect(ExecutionModeAdapters.fact(kind: .serviceTier, raw: "future-2", evidence: .served,
                                           provider: "openai", scope: .response).attribution(for: .serviceTier).mode == "future-2")
    }

    @Test func codexDefaultsAreOnlySourceConfiguration() throws {
        let temporary = try TempDirectory()
        let sessions = temporary.file("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "service_tier = 'priority' # declared default\n[profiles.work]\nservice_tier = 'ultrafast'\n".write(
            to: temporary.file("config.toml"), atomically: true, encoding: .utf8)
        let modes = ConfiguredModes.codex(sessionsRoot: sessions.path)
        #expect(modes.facts.first?.value == "fast")
        #expect(modes.facts.first?.evidence == .configured)
        #expect(modes.attribution(for: .serviceTier).isUnknown)
        #expect(ConfiguredModes.declaredTier("service_tier = false") == nil)
        #expect(ConfiguredModes.declaredTier("service_tier = false\nservice_tier = \"priority\"") == nil)
        #expect(ConfiguredModes.declaredTier("service_tier = \"default\"\nservice_tier = \"priority\"") == nil)
        for quote in ["\"\"\"", "'''"] {
            let spoof = "prompt = " + quote + "\nservice_tier = \"priority\"\n" + quote + "\n"
            #expect(ConfiguredModes.declaredTier(spoof) == nil)
            #expect(ConfiguredModes.declaredTier("service_tier = \"default\"\n" + spoof) == nil)
        }

        #expect(ConfiguredModes.declaredTier("service_tier = \"priority\\nsecret\"") == nil)
        try FileManager.default.removeItem(at: temporary.file("config.toml"))
        try FileManager.default.createSymbolicLink(at: temporary.file("config.toml"), withDestinationURL: temporary.file("elsewhere"))
        #expect(ConfiguredModes.codex(sessionsRoot: sessions.path).facts.isEmpty)
    }

    @Test func nativeMeaningAndZcodeFallback() throws {
        #expect(ExecutionModeAdapters.omp("priority", provider: "anthropic", evidence: .recorded, scope: .request)
            .attribution(for: .serviceTier).mode == "fast")
        #expect(ExecutionModeAdapters.omp("priority", provider: "anthropic", evidence: .recorded, scope: .request)
            .attribution(for: .serviceTier).evidence == "recorded")
        #expect(ExecutionModeAdapters.kimi("grok-code-fast-1").facts.isEmpty)
        #expect(ExecutionModeAdapters.routing("fast-model").attribution(for: .serviceTier).isUnknown)
        let metadata = try JSONParser.parse(Data(#"{"schemaVersion":1,"cardId":"card-1","model":"glm-5","fallbackAt":500}"#.utf8))
        let accelerated = ZcodeDatabase.highspeedModes(metadata, provider: "account:zai-highspeed-card", model: "glm-5", startedMs: 100)
        #expect(accelerated.attribution(for: .accelerator).evidence == "recorded")
        let fallback = ZcodeDatabase.highspeedModes(metadata, provider: "account:zai", model: "glm-5", startedMs: 501)
        #expect(fallback.attribution(for: .accelerator).mode == "standard")
        #expect(fallback.facts.allSatisfy { $0.evidence != .served })
        let mock = try JSONParser.parse(Data(#"{"schemaVersion":1,"cardId":"hsc_mock_1","model":"glm-5"}"#.utf8))
        #expect(ZcodeDatabase.highspeedModes(mock, provider: "account:zai-highspeed-card", model: "glm-5", startedMs: 100)
            .attribution(for: .accelerator).evidence == "selected")
    }

    @Test func aggregatePartitionsAndAdditivePersistence() throws {
        let known = ExecutionModeAdapters.claude("fast")
        let records = [record("known", modes: known), record("unknown")]
        var aggregate = DayAggregate()
        records.forEach { aggregate.add($0, cost: nil) }
        let database = try HistoryDatabase.inMemory()
        let key = UsageKey(day: "2026-10-24", source: .claudeCode)
        let entry = HistoryDatabase.Entry(family: "claude", size: 1, modified: 1, version: 4, days: [key: aggregate])
        _ = try database.save([(path: "/virtual/session", entry: entry, keys: [])])
        let loaded = try #require(try database.loadEntries()["/virtual/session"]?.days[key])
        #expect(loaded == aggregate)
        let day = loaded.usage(day: key.day, source: key.source, peak: nil, priceVersion: nil)
        for kind in ExecutionModeKind.allCases {
            let parts = day.modeBreakdown.filter { $0.attribution.kind == kind }
            #expect(parts.reduce(0) { $0 + $1.requests } == day.totals.requests)
            #expect(parts.reduce(0) { $0 + $1.output } == day.totals.output)
            #expect(parts.reduce(0) { $0 + $1.measuredOutput } == day.measuredOutput)
            #expect(parts.reduce(Int64(0)) { $0 + $1.measuredMs } == day.measuredMs)
        }
        #expect(HistoryDatabase.schemaVersion == 3)
        var legacy = day
        legacy.modeUsage = []; legacy.models = []
        #expect(legacy.modeBreakdown.filter { $0.attribution.kind == .serviceTier }.first?.requests == 2)
        let csv = String(decoding: ExecutionModeCSV.build([day], kind: .serviceTier), as: UTF8.self)
        #expect(csv.contains("fast,served,anthropic,1,100,100,1000,100.0\r\n"))
        #expect(csv.contains("unknown,unknown,,1,100,100,1000,100.0\r\n"))
    }

    @Test func historyUpsertsReplaceClassificationAcrossRestarts() throws {
        let scratch = try HistoryTests.Scratch()
        let original = HistoryTests.claude([("same-response", 100)])
        let timestamp = Date(timeIntervalSince1970: 1_792_490_500)
        try scratch.directory.write("claude/p/session.jsonl", original, modified: timestamp)
        let (_, before) = try scratch.run()
        #expect(before.first?.totals.requests == 1)
        #expect(before.first?.modeUsage.isEmpty == true)
        let enriched = original.replacingOccurrences(of: #""output_tokens":100"#, with: #""output_tokens":100,"speed":"fast""#)
        try scratch.directory.write("claude/p/session.jsonl", enriched, modified: timestamp.addingTimeInterval(10))
        let (_, after) = try scratch.run()
        #expect(after.first?.totals == before.first?.totals)
        #expect(after.first?.measuredMs == before.first?.measuredMs)
        #expect(after.first?.modeUsage.first?.attribution.mode == "fast")
        #expect(after.first?.modeUsage.first?.requests == 1)
        let (restarted, persisted) = try scratch.run()
        #expect(restarted.filesAnalyzed == 0)
        #expect(persisted == after)
    }

    @Test func invalidHistoryPartitionsFallBackAndCSVEscapesFormulaCells() {
        var aggregate = DayAggregate()
        aggregate.add(record("one"), cost: nil)
        var day = aggregate.usage(day: "2026-10-24", source: .claudeCode, peak: nil, priceVersion: nil)
        day.models[0].model = "=HYPERLINK(\"bad\",1)"
        day.modeUsage = [.init(model: day.models[0].model, attribution: .init(kind: .serviceTier, mode: "fast", evidence: "served"), requests: 2)]
        let parts = day.modeBreakdown.filter { $0.attribution.kind == .serviceTier }
        #expect(parts.count == 1 && parts[0].attribution.isUnknown && parts[0].requests == 1)
        let csv = String(decoding: ExecutionModeCSV.build([day], kind: .serviceTier), as: UTF8.self)
        #expect(csv.contains("\"'=HYPERLINK(\"\"bad\"\",1)\""))
    }

    private func record(_ key: String, modes: ExecutionModes = .empty) -> ResponseRecord {
        ResponseRecord(key: key, source: .claudeCode, agentId: "a", model: "m", startMs: 1_792_800_000_000,
                       endMs: 1_792_800_001_000, usage: TokenUsage(output: 100), modes: modes)
    }
}
