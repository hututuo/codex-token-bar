import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("DeepSeek Harness parser")
struct DshParserTests {
    static func run(_ lines: [String], deduper: inout Deduper, fileID: FileID = 0) -> (TranscriptParser, [ResponseUpsert]) {
        ParserBehaviorTests.run(.dsh, lines, path: "/d/s/session.v4.jsonl.zstd", deduper: &deduper, fileID: fileID)
    }

    static func header(id: String = "s1", created: Int64 = 1_000_000, extra: String = "") -> String {
        #"{"type":"session","version":4,"id":"\#(id)","createdAt":\#(created),"cwd":"/Users/dev/quasar"\#(extra)}"#
    }

    static func event(_ type: String, _ seq: Int, _ time: Int64, data: String = "{}") -> String {
        #"{"type":"\#(type)","seq":\#(seq),"time":\#(time),"data":\#(data)}"#
    }

    static func message(_ seq: Int, _ time: Int64, id: String?, blocks: [String] = ["text"], usage: String? = nil) -> String {
        let content = blocks.map { #"{"type":"\#($0)"}"# }.joined(separator: ",")
        let idMember = id.map { #","id":"\#($0)""# } ?? ""
        let usageMember = usage.map { #","usage":\#($0)"# } ?? ""
        let data = #"{"message":{"role":"assistant","content":[\#(content)],"source":{"model":"deepseek-pro"}\#(idMember)}\#(usageMember)}"#
        return event("assistant/message", seq, time, data: data)
    }

    static let usage = #"{"inputTokens":100,"outputTokens":50,"cacheReadTokens":1000,"cacheWriteTokens":10,"totalTokens":1160}"#

    @Test func measuresFromStepStartAndNormalizesUsage() throws {
        var deduper = Deduper()
        let (parser, upserts) = Self.run([
            Self.header(),
            Self.event("step/start", 1, 1_001_000),
            Self.message(2, 1_003_000, id: "m1", blocks: ["reasoning", "tool-call"], usage: Self.usage),
        ], deduper: &deduper)
        let record = try #require(upserts.first?.record)
        #expect(upserts.count == 1 && upserts[0].isCompletion)
        #expect(record.source == .deepseek)
        #expect(record.startMs == 1_001_000 && record.endMs == 1_003_000)
        #expect(record.usage == TokenUsage(input: 1110, cachedInput: 1000, cacheWriteInput: 10, output: 50, reasoning: 0))
        #expect(record.model == "deepseek-pro" && record.isFinal)
        #expect(parser.state.phase == .tools)
        #expect(parser.state.project == "quasar")
        #expect(parser.state.thread == SessionThread(id: "s1", parentId: nil, createdMs: 1_000_000))
    }

    @Test func unwrapsEventAndSnapshotLinesInAnyMemberOrder() {
        var deduper = Deduper()
        let snapshot = #"{"records":[\#(Self.event("step/start", 1, 1_001_000)),{"event":\#(Self.message(2, 1_002_000, id: "m1", usage: Self.usage)),"type":"event"},7],"#
            + #""header":{"id":"s1","createdAt":1000000,"parentSession":"root"},"type":"snapshot"}"#
        let (parser, upserts) = Self.run([
            snapshot,
            #"{"event":\#(Self.event("step/start", 3, 1_004_000)),"type":"event","time":1}"#,
            #"{"data":{"turn":1},"time":1005000,"seq":4,"type":"turn/end"}"#,
        ], deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["m1"])
        #expect(upserts.first?.record.startMs == 1_001_000)
        #expect(parser.state.isSubagent)
        #expect(parser.state.thread?.parentId == "root")
        #expect(parser.state.phase == .idle)
        #expect(parser.state.lastLineMs == 1_005_000)
        #expect(parser.state.malformedLines == 0)
    }

    @Test func ignoresHistoryInheritedFromTheParentSession() {
        var deduper = Deduper()
        let (parser, upserts) = Self.run([
            Self.header(created: 1_010_000, extra: #","origin":"subagent""#),
            Self.event("step/start", 1, 1_001_000),
            Self.message(2, 1_007_999, id: "inherited", usage: Self.usage),
            Self.event("step/start", 3, 1_008_000),
            Self.message(4, 1_012_000, id: "own", usage: Self.usage),
            Self.header(id: "later", created: 0),
        ], deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["own"])
        #expect(upserts.first?.record.startMs == 1_008_000)
        #expect(!deduper.contains("inherited"))
        #expect(parser.state.isSubagent)
        #expect(parser.state.thread?.id == "s1")
        #expect(parser.state.lastLineMs == 1_012_000)
    }

    @Test func messagesWithoutUsageOrSeenKeysOnlyMoveThePhase() {
        var deduper = Deduper()
        _ = deduper.claim("taken", for: 9)
        let (parser, upserts) = Self.run([
            Self.header(),
            Self.event("request/header", 1, 1_001_000, data: #"{"header":{"config":{"model":"deepseek-flash"}}}"#),
            Self.event("step/start", 2, 1_002_000),
            Self.message(3, 1_003_000, id: nil, blocks: ["tool-call"]),
            Self.event("step/start", 4, 1_004_000),
            Self.message(5, 1_005_000, id: "taken", usage: Self.usage),
            Self.event("step/start", 6, 1_006_000),
            Self.message(7, 1_007_000, id: nil, usage: Self.usage),
            Self.message(7, 1_008_000, id: nil, usage: Self.usage),
        ], deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["dsh:s1:7"])
        #expect(deduper.contains("dsh:s1:3"))
        #expect(parser.state.model == "deepseek-pro")
        // The skipped "taken" message left step 4 pending until step 6 replaced it.
        #expect(upserts.first?.record.startMs == 1_006_000)
        #expect(parser.state.phase == .idle)
    }

    @Test func requestHeadersNameTheModelUntilAMessageNamesItsOwn() {
        var deduper = Deduper()
        let bare = #"{"type":"assistant/message","seq":3,"time":1003000,"data":{"message":{"id":"m"},"usage":{"outputTokens":5}}}"#
        let (parser, upserts) = Self.run([
            Self.header(),
            Self.event("request/header", 1, 1_001_000, data: #"{"header":{"config":{"model":"deepseek-flash"}}}"#),
            Self.event("step/start", 2, 1_002_000),
            bare,
            "not json",
            "   ",
        ], deduper: &deduper)
        #expect(upserts.first?.record.model == "deepseek-flash")
        #expect(upserts.first?.record.usage.output == 5)
        #expect(parser.state.malformedLines == 1)
    }

    @Test func sessionFileNames() {
        let names = TranscriptNames.dshSession
        #expect(names.matches("session.v4.jsonl.zstd"))
        #expect(names.matches("session.v12.jsonl"))
        #expect(!names.matches("session.v.jsonl.zstd"))
        #expect(!names.matches("session.v4.jsonl.zstd.tmp"))
        #expect(!names.matches("session.lock"))
        #expect(!names.matches("other.jsonl"))
    }

    @Test func discoversOnlySessionFiles() throws {
        let directory = try TempDirectory()
        try directory.write("--w-quasar--/session-a/session.v4.jsonl.zstd", bytes: [])
        try directory.write("--w-quasar--/session-a/session.lock", "")
        try directory.write("--w-quasar--/session-b/session.v3.jsonl", "")
        try directory.write("--w-quasar--/session-b/notes.jsonl", "")
        let found = TranscriptDiscovery.enumerate(root: directory.path, names: .dshSession)
            .map { String($0.path.dropFirst(directory.path.count + 1)) }
        #expect(Set(found) == ["--w-quasar--/session-a/session.v4.jsonl.zstd", "--w-quasar--/session-b/session.v3.jsonl"])
    }
}
