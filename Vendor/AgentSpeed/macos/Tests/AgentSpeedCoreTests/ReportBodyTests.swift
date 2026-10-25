import Foundation
import Testing
@testable import AgentSpeedCore

/// REPORTING 6 / METRICS 11.2, 11.7: bodies built from windows and samples, checked against the schema and the strict
/// rules of spec/tools/report_reference.py (when python3 is available).
@Suite struct ReportBodyTests {
    static let envelope = ReportEnvelope(
        client: ReportClientInfo(version: "1.3.0", osMajor: 27), deviceId: "6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b",
        username: "小明的 Mac", runId: "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f", seq: 42, sentAtMs: 1_792_656_930_500,
        windowMs: 5000, activity: .active, titleLevel: 8)

    static func busySample(models: Int = 3, traffic: ReportTrafficSample.Status = .ok) -> (ReportWindowContent, ReportSample) {
        var counters = ReportCounters()
        let ids = ["claude-opus-5-5", "gpt-5.5", "unknown", "local"] + (0..<max(0, models - 4)).map { "model-\($0)" }
        for (index, id) in ids.prefix(max(models, 1)).enumerated() {
            let source: SourceKind = index % 2 == 0 ? .claudeCode : .codex
            counters.add(ReportUsage(requests: 2, output: Int64(900 - index * 10), input: 40_000, cachedInput: 30_000,
                                     cacheWriteInput: 1000, reasoning: 20, measuredOutput: Int64(800 - index * 10),
                                     measuredMs: 2100, costMicroUsd: id == "unknown" ? 0 : 1500,
                                     unpricedRequests: id == "unknown" ? 2 : 0),
                         to: ReportModelKey(modelId: id, source: source))
        }
        let facts = ReportLiveFacts(
            agents: [.claudeCode: ReportAgentCounts(generating: 2, tools: 1, active: 3),
                     .codex: ReportAgentCounts(generating: 1, tools: 0, active: 2),
                     .gemini: ReportAgentCounts(active: 1)],
            generatingModels: [ReportModelKey(modelId: "claude-opus-5-5", source: .claudeCode): 2,
                               ReportModelKey(modelId: "gpt-5.5", source: .codex): 1],
            counters: counters)
        let sources: [SourceKind: ReportSample.Source] = [
            .claudeCode: .init(live: Rate(output: 300.44, total: 150_220.16), liveEstimated: Rate(output: 36.05, total: 0),
                               liveCost: LiveCost(microUsdPerSecond: 3600.4, knownOutput: 300.44)),
            .codex: .init(live: Rate(output: 112.21, total: 32_120.09), liveEstimated: Rate(output: 52.7, total: 0),
                          liveCost: LiveCost(microUsdPerSecond: 612.6, knownOutput: 100)),
            .gemini: .init(live: Rate(output: 0.01, total: 0.02)),
        ]
        let live = Rate(output: 412.66, total: 182_340.27)
        let trafficSample = ReportTrafficSample(
            status: traffic, includesTools: true, rate: TrafficRate(rx: 24_310.4, tx: 1288.2),
            sourceRates: [.codex: TrafficRate(rx: 4200, tx: 288), .claudeCode: TrafficRate(rx: 20_110.4, tx: 1000.2)],
            totals: TrafficReportTotals(sources: [.codex: TrafficSplit(own: TrafficBytes(rx: 21_000, tx: 1440)),
                                                  .claudeCode: TrafficSplit(own: TrafficBytes(rx: 90_000, tx: 4000),
                                                                            tools: TrafficBytes(rx: 10_550, tx: 1000))]))
        let sample = ReportSample(live: live, estimatedShare: 0.2154, liveCost: LiveCost(microUsdPerSecond: 4213, knownOutput: 400.44),
                                  sources: sources, facts: facts, traffic: trafficSample)
        let window = ReportWindow(ReportSample(traffic: ReportTrafficSample(status: traffic)))
        var content = window.content(sample)
        content.peak = Rate(output: 655, total: 240_118.66)
        content.peakCost = 6120.2
        content.peakRate = TrafficRate(rx: 61_200, tx: 3410)
        return (content, sample)
    }

    static let everything = ReportOptions(sections: Set(ReportSection.allCases), metric: .output, redline: 2000)

    @Test func disabledSourcesReportNoTraffic() {
        let baseline = TrafficReportTotals(sources: [.codex: TrafficSplit(own: TrafficBytes(rx: 1000, tx: 100)),
                                                     .gemini: TrafficSplit(own: TrafficBytes(rx: 2000, tx: 200))])
        let totals = TrafficReportTotals(sources: [.codex: TrafficSplit(own: TrafficBytes(rx: 5000, tx: 500)),
                                                   .gemini: TrafficSplit(own: TrafficBytes(rx: 9000, tx: 900))])
        let sample = ReportTrafficSample(status: .ok, totals: totals, enabled: SourceSet(.codex))
        #expect(sample.agentBytes(since: baseline) == [.codex: TrafficBytes(rx: 4000, tx: 400)])
    }

    @Test func activeReportHasEverySectionAndExactSums() throws {
        let (content, sample) = Self.busySample()
        let json = ReportBody.json(Self.envelope, content, sample, Self.everything)
        let body = try JSONSerialization.jsonObject(with: json.compactData) as! [String: Any]
        #expect((body["client"] as? [String: Any])?["app"] as? String == "CodexTokenBar")
        let live = body["live"] as! [String: Any]
        #expect(live["outputTokS"] as? Double == 412.7)
        #expect(live["estimatedShare"] as? Double == 0.215)
        #expect((live["agents"] as! [String: Int]) == ["generating": 3, "tools": 1, "active": 6])
        let sources = body["sources"] as! [[String: Any]]
        #expect(sources.map { $0["source"] as! String } == ["codex", "claudeCode"], "gemini rounds to 0 and is idle")
        let models = body["models"] as! [[String: Any]]
        #expect(models.map { $0["id"] as! String } == ["claude-opus-5-5", "gpt-5.5", "unknown"])
        let title = body["title"] as! [String: Any]
        #expect(title["heat"] as? Double == 0.388)
        #expect(json.compactData.first == UInt8(ascii: "{"))
        #expect(!String(decoding: json.compactData, as: UTF8.self).contains("\n"))
    }

    @Test func modelsBeyondTheLimitMergeIntoOther() throws {
        let (content, sample) = Self.busySample(models: 9)
        var options = Self.everything
        options.maxModels = 4
        let body = try JSONSerialization.jsonObject(with: ReportBody.json(Self.envelope, content, sample, options).compactData)
            as! [String: Any]
        let models = body["models"] as! [[String: Any]]
        #expect(models.count == 4)
        #expect(models.last?["id"] as? String == "other")
        #expect(models.reduce(0) { $0 + ($1["requests"] as! Int) } == 18)
        options.maxModels = 0
        let none = try JSONSerialization.jsonObject(with: ReportBody.json(Self.envelope, content, sample, options).compactData)
            as! [String: Any]
        #expect(none["models"] == nil)
    }

    @Test func oversizeDropsModelsThenSources() throws {
        let (content, sample) = Self.busySample(models: 16)
        var options = Self.everything
        options.bodyLimit = 2600
        let body = try JSONSerialization.jsonObject(with: ReportBody.data(Self.envelope, content, sample, options)) as! [String: Any]
        #expect(body["models"] == nil)
        options.bodyLimit = 1200
        let smaller = ReportBody.data(Self.envelope, content, sample, options)
        let parsed = try JSONSerialization.jsonObject(with: smaller) as! [String: Any]
        #expect(parsed["models"] == nil && parsed["sources"] == nil && parsed["cost"] != nil)
    }

    @Test func unavailableTrafficIsAStatusNeverZero() throws {
        let (content, sample) = Self.busySample(traffic: .unavailable)
        let body = try JSONSerialization.jsonObject(with: ReportBody.json(Self.envelope, content, sample, Self.everything).compactData)
            as! [String: Any]
        #expect((body["traffic"] as! [String: String]) == ["status": "unavailable"])
        let sources = body["sources"] as! [[String: Any]]
        #expect(sources.allSatisfy { $0["traffic"] == nil })
    }

    /// A response of an earlier window priced only now: its source and model are listed with the cost section so
    /// every cost sum adds up, and left out without it (REPORTING 6.6.3, 6.6.4).
    static func latePriced() -> (ReportWindowContent, ReportSample) {
        var (content, sample) = busySample()
        content.usage.add(ReportUsage(costMicroUsd: 2500), to: ReportModelKey(modelId: "gemini-3.1-pro", source: .gemini))
        sample.sources[.gemini] = ReportSample.Source()
        return (content, sample)
    }

    @Test func latePricedSourcesAreListedWithTheCostSection() throws {
        let (content, sample) = Self.latePriced()
        let body = try JSONSerialization.jsonObject(with: ReportBody.json(Self.envelope, content, sample, Self.everything).compactData)
            as! [String: Any]
        let sources = body["sources"] as! [[String: Any]]
        #expect(sources.map { $0["source"] as! String } == ["codex", "claudeCode", "gemini"])
        let models = body["models"] as! [[String: Any]]
        #expect(models.contains { $0["id"] as? String == "gemini-3.1-pro" && $0["output"] as? Int == 0 })
        let total = (body["cost"] as! [String: Any])["deltaMicroUsd"] as! Int
        #expect(models.reduce(0) { $0 + ($1["deltaMicroUsd"] as! Int) } == total)
        #expect(sources.reduce(0) { $0 + (($1["cost"] as! [String: Any])["deltaMicroUsd"] as! Int) } == total)

        var options = Self.everything
        options.sections.remove(.cost)
        let withoutCost = try JSONSerialization.jsonObject(with: ReportBody.json(Self.envelope, content, sample, options).compactData)
            as! [String: Any]
        #expect((withoutCost["sources"] as! [[String: Any]]).map { $0["source"] as! String } == ["codex", "claudeCode"])
    }

    @Test func numbersAreRoundedHalfAwayFromZero() {
        #expect(ReportJSON.number(0.25, decimals: 1) == "0.3")
        #expect(ReportJSON.number(412.65, decimals: 1) == "412.7")
        #expect(ReportJSON.number(0.0004, decimals: 3) == "0")
        #expect(ReportJSON.number(2000, decimals: 1) == "2000")
        #expect(ReportJSON.number(0.215, decimals: 3) == "0.215")
        #expect(ReportJSON.quoted("a\"b\\c\n\u{01}é") == "\"a\\\"b\\\\c\\n\\u0001é\"")
    }

    /// Every body the builder makes passes the reference's schema and strict conformance rules.
    @Test(.enabled(if: ReferencePython.available)) func referenceAcceptsTheBodies() throws {
        var bodies: [Data] = []
        for models in [0, 3, 9, 16] {
            for traffic in [ReportTrafficSample.Status.ok, .off, .unavailable] {
                let (content, sample) = Self.busySample(models: models, traffic: traffic)
                for sections in [Set(ReportSection.allCases), [], [.sources, .cost], [.models, .traffic]] as [Set<ReportSection>] {
                    var options = Self.everything
                    options.sections = sections
                    options.maxModels = models == 9 ? 4 : 16
                    bodies.append(ReportBody.data(Self.envelope, content, sample, options))
                }
            }
        }
        var idle = Self.envelope
        idle.activity = .idle
        idle.titleLevel = 0
        let empty = ReportSample(traffic: ReportTrafficSample(status: .ok, includesTools: false, rate: nil))
        bodies.append(ReportBody.data(idle, ReportWindow(empty).content(empty), empty, Self.everything))
        let (late, lateSample) = Self.latePriced()
        for sections in [Set(ReportSection.allCases), [.sources, .models]] as [Set<ReportSection>] {
            var options = Self.everything
            options.sections = sections
            bodies.append(ReportBody.data(Self.envelope, late, lateSample, options))
        }
        let failures = try ReferencePython.strictErrors(bodies)
        #expect(failures.isEmpty, "\(failures)")
        #expect(!(try ReferencePython.strictErrors([Data(#"{"schema":1}"#.utf8)])).isEmpty, "the checker rejects a bad body")
    }
}

/// Runs spec/tools/report_reference.py's validator on bodies the Swift code produced.
enum ReferencePython {
    static let tools = Fixtures.root.deletingLastPathComponent().appendingPathComponent("tools")

    static let available: Bool = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
        && FileManager.default.fileExists(atPath: tools.appendingPathComponent("report_reference.py").path)

    static func strictErrors(_ bodies: [Data]) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("report-bodies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, body) in bodies.enumerated() {
            try body.write(to: directory.appendingPathComponent("\(index).json"))
        }
        let script = """
        import json, sys, pathlib
        sys.path.insert(0, sys.argv[1])
        import report_reference as r
        schema = r.load_schema()
        # Keep the upstream schema unchanged while accepting this app's client identity in generated report bodies.
        schema["$defs"]["client"]["properties"]["app"] = {"enum": ["AgentSpeed", "CodexTokenBar"]}
        bad = []
        for path in sorted(pathlib.Path(sys.argv[2]).glob('*.json')):
            body = json.loads(path.read_text(encoding='utf-8'))
            for error in r.report_errors(body, schema, strict=True):
                bad.append(f"{path.name}: {error}")
        print(json.dumps(bad))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, tools.path, directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode([String].self, from: output)
    }
}
