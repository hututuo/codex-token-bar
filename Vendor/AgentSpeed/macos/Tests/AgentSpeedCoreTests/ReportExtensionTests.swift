import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Report extensions")
struct ReportExtensionTests {
    @Test func sharedCapabilitiesAreExactIntegers() throws {
        let root = try Fixtures.json("execution-mode-cases.json")
        for item in try #require(root["capabilities"] as? [[String: Any]]) {
            let data = try JSONSerialization.data(withJSONObject: try #require(item["extensions"]))
            let caps = ReportExtensions(try JSONParser.parse(data))
            #expect((caps.executionModes && (item["modelsEnabled"] as? Bool == true)) == (item["expected"] as? Bool == true))
        }
        for raw in ["true", "null", "1.0", "1e0", "2", "\"1\""] {
            let value = try JSONParser.parse(Data("{\"executionModes\":\(raw),\"profileAvatar\":\(raw)}".utf8))
            #expect(ReportExtensions(value) == .none)
        }
        let caps = ReportExtensions(modelHarnessRequests: true, executionModes: true, profileAvatar: true, sharedIdentity: true)
        let bytes = try JSONEncoder().encode(caps)
        #expect(try JSONDecoder().decode(ReportExtensions.self, from: bytes) == caps)
    }

    @Test func lateMetadataStaysInOriginalReportAttribution() throws {
        var ledger = ReportLedger()
        var response = ReportLedgerTests.record("late", start: ReportLedgerTests.base - 1000, end: ReportLedgerTests.base,
                                               output: 20, final: false)
        ledger.count(response, modelId: "m")
        let baseline = ledger.counters
        response.modes = ExecutionModeAdapters.claude("fast")
        response.usage.output = 100
        response.isFinal = true
        ledger.grow(response, modelId: "m")
        let delta = ledger.counters.since(baseline)
        #expect(delta.total.requests == 0 && delta.total.output == 80)
        #expect(delta.byMode.isEmpty)
        let groups = try #require(ReportModelBreakdown.modes([.claudeCode: delta.total], groups: [:]))
        let rows = try #require(try JSONSerialization.jsonObject(with: groups.compactData) as? [[String: Any]])
        #expect(rows.first?.string("mode") == "unknown")
        #expect(rows.first?.int("measuredOutput") == 100 && rows.first?.int("measuredMs") == 1000)
        #expect(response.modes.attribution(for: .serviceTier).mode == "fast")
    }

    @Test func completeNativeAndUnknownBreakdownsPreserveOriginalModelIDs() throws {
        var counters = ReportCounters()
        let claude = ReportModelKey(modelId: "m", source: .claudeCode)
        let codex = ReportModelKey(modelId: "m", source: .codex)
        counters.add(ReportUsage(requests: 2, output: 200, measuredOutput: 200, measuredMs: 1000), to: claude,
                     modes: ExecutionModeAdapters.claude("fast").attributed)
        counters.add(ReportUsage(requests: 1, output: 80, measuredOutput: 0, measuredMs: 0), to: codex)
        let content = ReportWindowContent(usage: counters, agentBytes: [:], peak: .zero, peakCost: 0, peakRate: nil)
        let sample = ReportSample()
        var options = ReportOptions(sections: [.models], extensions: .init(modelHarnessRequests: true, executionModes: true))
        let legacy = ReportBody.json(ReportBodyTests.envelope, content, sample, .init(sections: [.models]))
        let json = ReportBody.json(ReportBodyTests.envelope, content, sample, options)
        let models = try #require(try JSONSerialization.jsonObject(with: json.compactData) as? [String: Any])["models"] as? [[String: Any]]
        let model = try #require(models?.first)
        #expect(models?.count == 1 && model.string("id") == "m")
        #expect((model["harnessRequests"] as? [[String: Any]])?.reduce(0) { $0 + $1.int("requests") } == model.int("requests"))
        let rows = try #require(model["modeUsage"] as? [[String: Any]])
        #expect(rows.count == 2)
        for field in ["requests", "output", "measuredOutput", "measuredMs"] {
            #expect(rows.reduce(0) { $0 + $1.int(field) } == model.int(field))
        }
        #expect(rows.contains { $0.string("mode") == "unknown" && $0.string("source") == "codex" })
        options.sections = []
        #expect(ReportBody.json(ReportBodyTests.envelope, content, sample, options)["models"] == nil)
        options.sections = [.models]
        options.bodyLimit = legacy.compactData.count + 2
        let fitted = ReportBody.fitted(ReportBodyTests.envelope, content, sample, options)
        #expect(fitted.data == legacy.compactData)
    }

    @Test func tooManyOrInvalidPartsAreOmittedCompletely() throws {
        var sources: [SourceKind: ReportUsage] = [:]
        for kind in SourceKind.allCases.prefix(9) { sources[kind] = ReportUsage(requests: 1) }
        #expect(ReportModelBreakdown.harness(sources, total: .init(requests: 9)) == nil)
        var groups: [ReportModeGroup: ReportUsage] = [:]
        for index in 0..<65 {
            let key = ReportModeGroup(source: .codex, attribution: .init(kind: .serviceTier, mode: "tier\(index)", evidence: "served", provider: "openai"))
            groups[key] = ReportUsage(requests: 1)
        }
        #expect(ReportModelBreakdown.modes([.codex: .init(requests: 65)], groups: groups) == nil)
        let bad = ReportModeGroup(source: .codex, attribution: .init(kind: .serviceTier, mode: "fast", evidence: "configured"))
        #expect(ReportModelBreakdown.modes([.codex: .init(requests: 1)], groups: [bad: .init(requests: 1)]) == nil)
    }
}
