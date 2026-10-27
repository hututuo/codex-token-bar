import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Parser behavior")
struct ParserBehaviorTests {
    static func run(_ family: TranscriptFamily, _ lines: [String], path: String = "/tmp/agent.jsonl", deduper: inout Deduper, fileID: FileID = 0) -> (TranscriptParser, [ResponseUpsert]) {
        var parser = TranscriptParser(family: family, agentId: path, fileID: fileID)
        var upserts: [ResponseUpsert] = []
        for line in lines {
            var copy = line
            copy.withUTF8 { buffer in
                parser.consume(rawLine: UnsafeRawBufferPointer(buffer), deduper: &deduper) { upserts.append($0) }
            }
        }
        return (parser, upserts)
    }

    static func claudeUser(_ ts: String, content: String) -> String {
        #"{"type":"user","entrypoint":"cli","cwd":"/w/p","message":{"role":"user","content":\#(content)},"timestamp":"\#(ts)"}"#
    }

    static func claudeAssistant(_ ts: String, id: String, output: Int, stop: String = "null") -> String {
        #"{"type":"assistant","entrypoint":"cli","cwd":"/w/p","message":{"id":"\#(id)","model":"m","stop_reason":\#(stop),"usage":{"input_tokens":1,"output_tokens":\#(output)}},"timestamp":"\#(ts)"}"#
    }

    @Test func claudeInterruptEndsTheTurn() {
        var deduper = Deduper()
        let (parser, _) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""go""#),
            Self.claudeUser("2026-10-20T10:00:05Z", content: #"[{"type":"text","text":"[Request interrupted by user for tool use]"}]"#),
            Self.claudeAssistant("2026-10-20T10:00:09Z", id: "late", output: 5),
        ], deduper: &deduper)
        // The interrupt cleared the pending start, so the late response has no start.
        #expect(parser.state.phase == .generating)
        let (stringInterrupt, _) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""go""#),
            Self.claudeUser("2026-10-20T10:00:05Z", content: #""[Request interrupted by user]""#),
        ], deduper: &deduper)
        #expect(stringInterrupt.state.phase == .idle)
        #expect(stringInterrupt.state.inFlightStartMs == nil)
    }

    @Test func claudeResponseAfterInterruptHasUnknownStart() {
        var deduper = Deduper()
        let (_, upserts) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""go""#),
            Self.claudeUser("2026-10-20T10:00:05Z", content: #"[{"type":"tool_result","content":"x"},{"type":"text","text":"[Request interrupted by user]"}]"#),
            Self.claudeAssistant("2026-10-20T10:00:09Z", id: "late", output: 5, stop: #""end_turn""#),
        ], deduper: &deduper)
        #expect(upserts.count == 1)
        #expect(upserts.first?.record.startMs == nil)
    }

    @Test func claudeMergesRepeatedLinesAndMarksOnlyTheFirstAsCompletion() {
        var deduper = Deduper()
        let (parser, upserts) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""go""#),
            Self.claudeAssistant("2026-10-20T10:00:02Z", id: "m1", output: 10),
            Self.claudeAssistant("2026-10-20T10:00:04Z", id: "m1", output: 30, stop: #""tool_use""#),
        ], deduper: &deduper)
        #expect(upserts.map(\.isCompletion) == [true, false])
        #expect(upserts.last?.record.usage.output == 30)
        #expect(upserts.last?.record.endMs == 1_792_490_404_000)
        #expect(upserts.last?.record.startMs == 1_792_490_400_000)
        #expect(parser.state.phase == .tools)
    }

    @Test func claudeIgnoresKeysOwnedByAnotherFile() {
        var deduper = Deduper()
        _ = Self.run(.claude, [Self.claudeAssistant("2026-10-20T10:00:02Z", id: "shared", output: 10)], path: "/a.jsonl", deduper: &deduper, fileID: 1)
        let (parser, upserts) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""go""#),
            Self.claudeAssistant("2026-10-20T10:00:02Z", id: "shared", output: 10, stop: #""end_turn""#),
            Self.claudeAssistant("2026-10-20T10:00:06Z", id: "own", output: 7, stop: #""end_turn""#),
        ], path: "/b.jsonl", deduper: &deduper, fileID: 2)
        #expect(upserts.map(\.record.key) == ["own"])
        // The ignored line did not consume the pending start.
        #expect(upserts.first?.record.startMs == 1_792_490_400_000)
        #expect(parser.state.phase == .idle)
    }

    @Test func countsMalformedLinesButNotBlankOnes() {
        var deduper = Deduper()
        let (parser, _) = Self.run(.codex, [
            "", "   ", "not json", "[1,2]", "{\"timestamp\":", "{\"timestamp\":\"2026-10-20T10:00:00Z\",\"type\":\"event_msg\"}\r",
        ], deduper: &deduper)
        #expect(parser.state.malformedLines == 3)
        #expect(parser.state.lastLineMs == 1_792_490_400_000)
    }

    @Test func codexUsesOnlyTheFirstSessionMeta() {
        var deduper = Deduper()
        let (parser, upserts) = Self.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"child","cwd":"/w/child","thread_source":"subagent","agent_path":"/root/worker"}}"#,
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"parent","cwd":"/w/parent","thread_source":"user"}}"#,
            #"{"timestamp":"2026-10-20T10:00:01Z","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/worker","content":[]}}"#,
            #"{"timestamp":"2026-10-20T10:00:03Z","type":"token_usage_record","payload":{"usage":{"input_tokens":5,"output_tokens":9}}}"#,
        ], deduper: &deduper)
        #expect(parser.state.isSubagent)
        #expect(parser.state.project == "child")
        #expect(upserts.first?.record.key == "codex:child:1792490403000")
        #expect(upserts.first?.record.startMs == 1_792_490_401_000)
    }

    @Test func codexMailboxInputMarksStartWithoutChangingPhase() {
        var deduper = Deduper()
        let (parser, _) = Self.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"root"}}"#,
            #"{"timestamp":"2026-10-20T10:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-10-20T10:00:05Z","type":"response_item","payload":{"type":"agent_message","author":"/root/w","recipient":"/root","content":[]}}"#,
        ], deduper: &deduper)
        #expect(parser.state.phase == .idle)
        #expect(parser.state.inFlightStartMs == nil)
    }

    @Test func codexTokenCountWhileStreamingEndsTheResponse() {
        var deduper = Deduper()
        let (parser, upserts) = Self.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"root"}}"#,
            #"{"timestamp":"2026-10-20T10:00:01Z","type":"event_msg","payload":{"type":"user_message"}}"#,
            #"{"timestamp":"2026-10-20T10:00:02Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"output_tokens":9}}}"#,
            #"{"timestamp":"2026-10-20T10:00:03Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-10-20T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"2026-10-20T10:13:00Z","type":"response_item","payload":{"type":"agent_message","author":"/root/w","recipient":"/root","content":[]}}"#,
            #"{"timestamp":"2026-10-20T10:13:02Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-10-20T10:13:05Z","type":"token_usage_record","payload":{"response_id":"r2","usage":{"output_tokens":30}}}"#,
        ], deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["r1", "r2"])
        #expect(upserts.last?.record.startMs == Timestamp.parse("2026-10-20T10:13:00Z"))
        #expect(parser.state.phase == .tools)
    }

    @Test func codexIgnoresCopiedHistory() {
        var deduper = Deduper()
        let (parser, upserts) = Self.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:10Z","type":"session_meta","payload":{"id":"t"}}"#,
            #"{"timestamp":"2026-10-20T10:00:07Z","type":"token_usage_record","payload":{"response_id":"old","usage":{"output_tokens":9}}}"#,
            #"{"timestamp":"2026-10-20T10:00:08.500Z","type":"token_usage_record","payload":{"response_id":"recent","usage":{"output_tokens":9}}}"#,
        ], deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["recent"])
        #expect(parser.state.lastLineMs == 1_792_490_410_000)
    }

    @Test func codexSurvivesHostileNumbers() {
        var deduper = Deduper()
        let (_, upserts) = Self.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:10Z","type":"token_usage_record","payload":{"response_id":"r","usage":{"input_tokens":1e400,"output_tokens":-7,"cached_input_tokens":"12","reasoning_output_tokens":99999999999999999999999}}}"#,
        ], deduper: &deduper)
        let usage = upserts.first?.record.usage
        #expect(usage?.input == Int(TokenCount.ceiling))
        #expect(usage?.output == 0)
        #expect(usage?.cachedInput == 0)
        #expect(usage?.reasoning == Int(TokenCount.ceiling))
    }

    @Test func summedTokenFieldsSaturateAtTheCap() {
        var deduper = Deduper()
        let (_, upserts) = Self.run(.claude, [
            #"{"type":"assistant","entrypoint":"cli","cwd":"/w/p","message":{"id":"big","model":"m","stop_reason":"end_turn","usage":{"input_tokens":900000000000,"cache_creation_input_tokens":900000000000,"cache_read_input_tokens":1e999,"output_tokens":5}},"timestamp":"2026-10-20T10:00:10Z"}"#,
        ], deduper: &deduper)
        let usage = upserts.first?.record.usage
        #expect(usage?.input == Int(TokenCount.ceiling), "input + cache writes + cache reads saturates (METRICS 3.2)")
        #expect(usage?.cachedInput == Int(TokenCount.ceiling))
        #expect(usage?.cacheWriteInput == 900_000_000_000)
        #expect(TokenCount.sum(Int(TokenCount.ceiling), Int(TokenCount.ceiling), 7) == Int(TokenCount.ceiling))
    }

    @Test func dedupeEvictsOldestKeysFirst() {
        var deduper = Deduper(capacity: 3)
        #expect(deduper.claim("a", for: 1) == .new)
        #expect(deduper.claim("b", for: 1) == .new)
        #expect(deduper.claim("c", for: 2) == .new)
        #expect(deduper.claim("a", for: 2) == .otherFile)
        #expect(deduper.claim("d", for: 2) == .new)
        #expect(!deduper.contains("a"))
        #expect(deduper.claim("b", for: 1) == .sameFile)
        #expect(deduper.count == 3)
    }
}
