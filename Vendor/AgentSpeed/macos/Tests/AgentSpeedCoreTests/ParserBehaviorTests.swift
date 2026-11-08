import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Parser behavior")
struct ParserBehaviorTests {
    @Test(arguments: TranscriptFamily.allCases)
    func stateProjectionSelectsTheLiveFamilyAndKeepsIndependentValueCopies(_ family: TranscriptFamily) {
        var parser=TranscriptParser(family:family,agentId:"/fixture/session",fileID:17)
        let original=parser
        let before=parser.state
        parser.noteMalformedLine()
        #expect(parser.state.source == before.source)
        #expect(parser.state.malformedLines == before.malformedLines + 1)
        #expect(original.state.malformedLines == before.malformedLines)
        #expect(family.sources.contains(parser.state.source))
    }

    @Test(arguments: TranscriptFamily.allCases)
    func trackedStateProjectionObservesMutationsAndResetWithoutChangingParser(_ family: TranscriptFamily) {
        let stat=FileStat(identity:.init(device:1,inode:17),size:0,modifiedNs:0,isRegularFile:true)
        let file=TrackedFile(path:"/fixture/session",family:family,root:"/fixture",fileID:17,stat:stat,start:.beginning)
        let original=file.parser
        for _ in 0..<20 {
            #expect(file.state == original.state)
            #expect(file.isUnsupported == original.isUnsupported)
        }
        file.parser.noteMalformedLine()
        #expect(file.state == file.parser.state)
        #expect(file.state.malformedLines == original.state.malformedLines+1)
        #expect(original.state.malformedLines == 0)
        file.resetParser()
        #expect(file.state == original.state)
        #expect(file.isUnsupported == original.isUnsupported)
    }

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

    @Test func claudeDisplayTitleUsesFirstDirectUserTextAndSurvivesLaterAssistantLines() {
        var deduper = Deduper()
        let user = #"{"type":"user","entrypoint":"cli","message":{"role":"user","content":[{"type":"tool_result","content":"not a task title"},{"type":"text","text":"<system-reminder>private reminder</system-reminder>\nInspect\u0000cache eviction\nLater context"}]},"timestamp":"2026-10-20T10:00:00Z"}"#
        let (parser, _) = Self.run(.claude, [
            user,
            Self.claudeAssistant("2026-10-20T10:00:02Z", id: "title-followup", output: 8, stop: #""end_turn""#),
            Self.claudeUser("2026-10-20T10:00:03Z", content: #""later request title""#),
        ], path: "/p/session/subagents/agent-worker.jsonl", deduper: &deduper)
        #expect(parser.state.isSubagent)
        #expect(parser.state.displayTitle == "Inspect cache eviction")
        #expect(EngineAgent(id: "/p/session/subagents/agent-worker.jsonl", state: parser.state).displayTitle == "Inspect cache eviction")

        let reordered = #"{"message":{"role":"user","content":"Late type metadata still labels this task"},"type":"user","timestamp":"2026-10-20T10:00:00Z"}"#
        let (reorderedParser, _) = Self.run(.claude, [reordered], path: "/p/session/subagents/agent-reordered.jsonl", deduper: &deduper)
        #expect(reorderedParser.state.displayTitle == "Late type metadata still labels this task")
    }

    @Test func claudeExplicitAgentNameWinsOnMetadataOnlyRecordAndNoLabelIsInvented() throws {
        var deduper = Deduper()
        let (parser, _) = Self.run(.claude, [
            #"{"type":"progress","title":"lower priority","agentName":"Explore"}"#,
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""fallback request""#),
            Self.claudeAssistant("2026-10-20T10:00:02Z", id: "title-followup", output: 8, stop: #""end_turn""#),
        ], path: "/p/session/subagents/agent-worker.jsonl", deduper: &deduper)
        #expect(parser.state.displayTitle == "Explore")

        let (custom, _) = Self.run(.claude, [
            #"{"type":"progress","customTitle":"First task name"}"#,
            #"{"type":"progress","customTitle":"Renamed task"}"#,
        ], path: "/p/session/subagents/agent-custom-title.jsonl", deduper: &deduper)
        #expect(custom.state.displayTitle == "Renamed task")

        let resultOnly = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ignored result"}]},"timestamp":"2026-10-20T10:00:00Z"}"#
        let (unnamed, _) = Self.run(.claude, [resultOnly], path: "/p/session/subagents/agent-unnamed.jsonl", deduper: &deduper)
        #expect(unnamed.state.displayTitle == nil)

        let oversizedMetadata = try JSONSerialization.data(withJSONObject: [
            "type": "progress",
            "agentName": String(repeating: "x", count: 20_000),
        ])
        let oversizedLine = String(decoding: oversizedMetadata, as: UTF8.self)
        let (oversized, _) = Self.run(.claude, [oversizedLine], path: "/p/session/subagents/agent-oversized.jsonl", deduper: &deduper)
        #expect(oversized.state.displayTitle == nil)
    }

    @Test func claudeDisplayTitleTruncatesByUnicodeCharacters() throws {
        var deduper = Deduper()
        let text = String(repeating: "界", count: 125)
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "timestamp": "2026-10-20T10:00:00Z",
            "message": ["role": "user", "content": text],
        ])
        let line = String(decoding: data, as: UTF8.self)
        let (parser, _) = Self.run(.claude, [line], path: "/p/session/subagents/agent-unicode.jsonl", deduper: &deduper)
        #expect(parser.state.displayTitle?.unicodeScalars.count == 120)

        let complex = String(repeating: "👩‍💻e\u{301}", count: 125)
        let complexData = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "timestamp": "2026-10-20T10:00:00Z",
            "message": ["role": "user", "content": complex],
        ])
        let complexLine = String(decoding: complexData, as: UTF8.self)
        let (complexParser, _) = Self.run(.claude, [complexLine], path: "/p/session/subagents/agent-complex.jsonl", deduper: &deduper)
        #expect(complexParser.state.displayTitle?.unicodeScalars.count == 120)
    }

    @Test func claudeLongInterruptKeepsPhaseHandlingAndSystemOnlyTextHasNoTitle() throws {
        var deduper = Deduper()
        let longInterrupt = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "timestamp": "2026-10-20T10:00:02Z",
            "message": ["role": "user", "content": "[Request interrupted by user" + String(repeating: "x", count: 20_000)],
        ])
        let longLine = String(decoding: longInterrupt, as: UTF8.self)
        let (interrupted, _) = Self.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", content: #""start work""#),
            longLine,
        ], deduper: &deduper)
        #expect(interrupted.state.phase == .idle)

        let systemOnly = #"{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>private reminder</system-reminder>"}]}}"#
        let commandOnly = #"{"type":"user","timestamp":"2026-10-20T10:00:02Z","message":{"role":"user","content":[{"type":"text","text":"<command-name>help</command-name>"}]}}"#
        let (unnamed, _) = Self.run(.claude, [systemOnly, commandOnly], path: "/p/session/subagents/agent-system.jsonl", deduper: &deduper)
        #expect(unnamed.state.displayTitle == nil)
    }

    @Test func claudeLongUserTextDoesNotBecomeTitleOrBlockUsageParsing() throws {
        var deduper = Deduper()
        let longUserText = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "timestamp": "2026-10-20T10:00:00Z",
            "message": ["role": "user", "content": String(repeating: "x", count: 20_000)],
        ])
        let line = String(decoding: longUserText, as: UTF8.self)
        let (parser, upserts) = Self.run(.claude, [
            line,
            Self.claudeAssistant("2026-10-20T10:00:02Z", id: "long-user-followup", output: 9, stop: #""end_turn""#),
        ], path: "/p/session/subagents/agent-long-user.jsonl", deduper: &deduper)
        #expect(parser.state.displayTitle == nil)
        #expect(upserts.first?.record.usage.output == 9)
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
