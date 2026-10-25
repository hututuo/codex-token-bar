import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Harness edge cases")
struct HarnessEdgeTests {
    static let base: Int64 = 1_792_497_600_000

    static func grokTurn(prompt: String = "pending-prompt") -> String {
        """
        {"timestamp":1792497603,"method":"_x.ai/session/update","params":{"sessionId":"one","update":{"sessionUpdate":"turn_completed","prompt_id":"\(prompt)","usage":{"inputTokens":1200,"cachedReadTokens":300,"outputTokens":200,"modelCalls":2,"apiDurationMs":2000,"modelUsage":{"grok-4.5":{"inputTokens":1200,"cachedReadTokens":300,"outputTokens":200,"modelCalls":2,"apiDurationMs":2000}}}},"_meta":{"agentTimestampMs":1792497603000}}}

        """
    }

    @Test func lateGrokSummaryFlushesIndependentUsageWithoutAnotherTranscriptLine() throws {
        let directory = try TempDirectory()
        let wire = "sessions/work/one/updates.jsonl"
        let summary = "sessions/work/one/summary.json"
        try directory.write(wire, Self.grokTurn())
        let configuration = MonitorConfiguration(enabledSources: [.grokBuild], grokBuildRoot: directory.file("sessions"))
        let session = TranscriptSession(configuration: configuration, clock: { Self.base + 5000 })
        _ = session.seed(todayStartMs: Self.base)
        #expect(session.responses.isEmpty)
        let store = directory.file("history.sqlite").path
        #expect(try HistoryScan.run(configuration: configuration, storePath: store).days.isEmpty)
        try directory.write(summary, #"{"info":{"id":"one","cwd":"/projects/nova"},"current_model_id":"grok-4.5"}"#)
        #expect(session.handleChanges(atCanonicalPaths: [try WorkBuddySessionTests.canonical(directory.file(summary).path)]))
        #expect(session.responses.count == 1 && session.responses.first?.requestCount == 2)
        #expect(session.responses.first?.usage.output == 200)
        _ = session.rediscover(todayStartMs: Self.base)
        #expect(session.responses.count == 1)
        let history = try HistoryScan.run(configuration: configuration, storePath: store)
        #expect(history.days.first?.totals.requests == 2 && history.days.first?.totals.output == 200)
    }

    @Test func lateGrokSubagentSummaryDropsPendingUsage() throws {
        let directory = try TempDirectory()
        let wire = "sessions/work/child/updates.jsonl"
        let summary = "sessions/work/child/summary.json"
        try directory.write(wire, Self.grokTurn())
        let configuration = MonitorConfiguration(enabledSources: [.grokBuild], grokBuildRoot: directory.file("sessions"))
        let session = TranscriptSession(configuration: configuration)
        _ = session.seed(todayStartMs: Self.base)
        #expect(session.responses.isEmpty)
        try directory.write(summary, #"{"info":{"id":"child","cwd":"/projects/nova"},"session_kind":"subagent","parent_session_id":"parent"}"#)
        #expect(session.rediscover(todayStartMs: Self.base))
        #expect(session.responses.isEmpty && session.sessionCounts(todayStartMs: Self.base)[.grokBuild] == nil)
        try directory.append(wire, Self.grokTurn(prompt: "second-child-prompt"))
        _ = session.handleChanges(atCanonicalPaths: [try WorkBuddySessionTests.canonical(directory.file(wire).path)])
        #expect(session.responses.isEmpty)
    }

    @Test func grokParentResolutionSupportsWorktreesAndPrefersSameWorkspace() {
        let first = AgentParents.Member(id: "/sessions/work-a/p/updates.jsonl", family: .grokBuild,
                                        thread: SessionThread(id: "parent", parentId: nil, createdMs: 1))
        let sameWorkspace = AgentParents.Member(id: "/sessions/work-b/p-copy/updates.jsonl", family: .grokBuild,
                                                thread: SessionThread(id: "parent", parentId: nil, createdMs: 2))
        let child = AgentParents.Member(id: "/sessions/work-b/child/updates.jsonl", family: .grokBuild,
                                        thread: SessionThread(id: "child", parentId: "parent", createdMs: 3))
        let other = AgentParents.Member(id: "/sessions/work-c/other/updates.jsonl", family: .grokBuild,
                                        thread: SessionThread(id: "other", parentId: "parent", createdMs: 4))
        let links = AgentParents.resolve([first, sameWorkspace, child, other])
        #expect(links[child.id] == sameWorkspace.id && links[other.id] == first.id)
    }

    @Test func kimiIgnoresPartialMessagesAndPreservesRequestStartBeforeStepBegin() {
        let text = """
        {"type":"llm.request","agentId":"main","time":1792497601000,"model":"kimi-k2.5"}
        {"type":"context.append_loop_event","agentId":"main","time":1792497602000,"event":{"type":"step.begin"}}
        {"type":"context.append_message","agentId":"main","time":1792497603000,"message":{"role":"assistant","id":"partial","partial":true,"usage":{"inputOther":10,"output":1}}}
        {"type":"context.append_message","agentId":"main","time":1792497605000,"message":{"role":"assistant","id":"partial","usage":{"inputOther":10,"output":40},"llmTiming":{"llmFirstTokenLatencyMs":500,"llmStreamDurationMs":1000}}}

        """
        var parser = KimiParser(agentId: "/sessions/work/sid/agents/main/wire.jsonl", fileID: 0)
        var deduper = Deduper()
        var records: [ResponseRecord] = []
        forEachLine(in: Data(text.utf8)) { bytes in
            parser.consume(KimiLineExtractor.extract(bytes), deduper: &deduper) { records.append($0.record) }
        }
        #expect(records.count == 1 && records.first?.usage.output == 40)
        #expect(records.first?.startMs == Self.base + 1000 && records.first?.endMs == Self.base + 5000)
    }

    @Test func harnessNumbersReuseExistingTruncationSaturationAndReasoningRules() throws {
        let kimi = #"{"type":"context.append_message","time":1792497605000,"message":{"role":"assistant","id":"numeric","usage":{"inputOther":12.9,"inputCacheRead":1e1,"inputCacheCreation":1e999,"output":999999999999999999999999999,"raw":{"reasoning_tokens":1e2}}}}"#
        var parser = KimiParser(agentId: "/sessions/work/sid/agents/main/wire.jsonl", fileID: 0)
        var deduper = Deduper()
        var records: [ResponseRecord] = []
        Data(kimi.utf8).withUnsafeBytes { parser.consume(KimiLineExtractor.extract($0), deduper: &deduper) { records.append($0.record) } }
        let record = try #require(records.first)
        #expect(record.usage.input == 1_000_000_000_000 && record.usage.cachedInput == 10)
        #expect(record.usage.cacheWriteInput == 1_000_000_000_000 && record.usage.output == 1_000_000_000_000)
        #expect(record.usage.reasoning == 100)
        let grok = #"{"timestamp":1792497603,"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":12.9,"outputTokens":3e2,"cachedReadTokens":2.5,"reasoningTokens":1e999,"modelCalls":12.9,"apiDurationMs":2.5}},"_meta":{"agentTimestampMs":1792497603000}}}"#
        var extracted: GrokBuildLine?
        Data(grok.utf8).withUnsafeBytes { if case .line(let line) = GrokBuildLine.extract($0) { extracted = line } }
        let batch = try #require(extracted?.batches.first)
        #expect(batch.usage.input == 12 && batch.usage.output == 300 && batch.usage.cachedInput == 2)
        #expect(batch.usage.reasoning == 300 && batch.requestCount == 12 && batch.durationMs == 2)
    }

    @Test func pendingGrokUsageIsBoundedAndMetadataSymlinksAreNotRead() throws {
        let directory = try TempDirectory()
        let wire = directory.file("sessions/work/one/updates.jsonl")
        try directory.write("sessions/work/one/updates.jsonl", "")
        let outside = try directory.write("outside.json", #"{"info":{"id":"one"}}"#)
        let summary = wire.deletingLastPathComponent().appendingPathComponent("summary.json")
        try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: outside)
        var parser = GrokBuildParser(agentId: wire.path, fileID: 0)
        var deduper = Deduper()
        var records: [ResponseRecord] = []
        for index in 0...GrokBuildParser.pendingLimit {
            forEachLine(in: Data(Self.grokTurn(prompt: "p\(index)").utf8)) { bytes in
                parser.consume(GrokBuildLine.extract(bytes), deduper: &deduper) { records.append($0.record) }
            }
        }
        #expect(records.isEmpty && parser.partialHistory)
    }
}
