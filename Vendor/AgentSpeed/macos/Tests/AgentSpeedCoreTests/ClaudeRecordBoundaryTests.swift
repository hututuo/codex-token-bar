import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Claude record boundaries")
struct ClaudeRecordBoundaryTests {
    enum ContentShape: CaseIterable, Sendable {
        case plainText
        case structuredToolResult
    }

    /// Uses the real selective extractor and Claude state machine after FileTailer
    /// assembles each line. It deliberately does not retain raw conversation bytes.
    private final class Harness {
        var parser: ClaudeParser
        var deduper = Deduper()
        var lines: [ClaudeLine] = []
        var lineSizes: [Int] = []
        var upserts: [ResponseUpsert] = []

        init(path: String) {
            parser = ClaudeParser(agentId: path, fileID: 17)
        }

        func read(_ tailer: inout FileTailer) -> FileTailer.ReadResult {
            tailer.read { bytes in
                lineSizes.append(bytes.count)
                let extraction = ClaudeLineExtractor.extract(bytes)
                if case .line(let line) = extraction { lines.append(line) }
                var emitted: [ResponseUpsert] = []
                parser.consume(extraction, deduper: &deduper) { emitted.append($0) }
                upserts.append(contentsOf: emitted)
            }
        }
    }

    @Test(arguments: ContentShape.allCases)
    func extractsClaudeUsageBeyondOneChunkAndKeepsShortSuccessor(_ shape: ContentShape) throws {
        let directory = try TempDirectory()
        let source = directory.file("session.jsonl")
        // More than 4 MiB + LF: JSON fields, not just LF, cross the read chunk.
        let large = try Self.record(id: "large", seed: 1, bytes: FileTailer.chunkBytes + 257, shape: shape)
        let after = try Self.record(id: "after", seed: 2)
        try (large + after).write(to: source)
        var tailer = FileTailer(path: source.path)
        let harness = Harness(path: source.path)

        let read = harness.read(&tailer)
        #expect(FileTailer.chunkBytes == 4 * 1_024 * 1_024)
        // Configured-cap discard/recovery remains covered by
        // FileTailerTests.skipsOversizedLines; this suite adds Claude semantics.
        #expect(tailer.maxLineBytes == 32 * 1_024 * 1_024)
        #expect(large.count - 1 < tailer.maxLineBytes)
        #expect(!read.failed)
        #expect(!read.didReset)
        #expect(read.bytesRead == large.count + after.count)
        #expect(tailer.offset == Int64(large.count + after.count))
        #expect(tailer.oversizedLines == 0)
        #expect(harness.lineSizes == [large.count - 1, after.count - 1])
        try Self.expectSemantics(harness, keys: ["large", "after"])

        let idle = harness.read(&tailer)
        #expect(idle.bytesRead == 0)
        #expect(!idle.failed)
        #expect(!idle.didReset)
        #expect(harness.upserts.count == 2)
        #expect(harness.lines.count == 2)

        // Explicitly reread the file with the same parser/deduper. Same-file
        // replay emits unchanged updates, but never new response completions.
        let originalRecords = harness.upserts.map(\.record)
        tailer.restart()
        let replayed = harness.read(&tailer)
        #expect(!replayed.failed)
        #expect(replayed.bytesRead == large.count + after.count)
        #expect(harness.upserts.count == 4)
        #expect(harness.upserts.filter(\.isCompletion).count == 2)
        #expect(harness.upserts.suffix(2).allSatisfy { !$0.isCompletion })
        #expect(harness.upserts.suffix(2).map(\.record) == originalRecords)
        #expect(harness.parser.state.malformedLines == 0)
        #expect(tailer.oversizedLines == 0)
    }

    @Test(arguments: ContentShape.allCases)
    func buffers4MiBPlusOneRecordAcrossAppendsUntilLFThenExtractsUsage(_ shape: ContentShape) throws {
        let directory = try TempDirectory()
        let source = directory.file("session.jsonl")
        // Sizes include LF, matching the historical scanner fixture convention.
        // This live path has its own 32 MiB line limit and accepts 4 MiB + 1.
        let large = try Self.record(id: "large", seed: 1, bytes: FileTailer.chunkBytes + 1, shape: shape)
        let after = try Self.record(id: "after", seed: 2)
        let firstEnd = FileTailer.chunkBytes - 31
        try Data(large.prefix(firstEnd)).write(to: source)
        var tailer = FileTailer(path: source.path)
        let harness = Harness(path: source.path)

        let first = harness.read(&tailer)
        #expect(!first.failed)
        #expect(first.bytesRead == firstEnd)
        #expect(tailer.offset == Int64(firstEnd))
        #expect(harness.lines.isEmpty)
        #expect(harness.upserts.isEmpty)
        #expect(harness.parser.state.malformedLines == 0)
        #expect(harness.read(&tailer).bytesRead == 0)

        // Finish the JSON object without its LF. Complete JSON is still pending.
        let remainder = Data(large[firstEnd..<(large.count - 1)])
        try Self.append(remainder, to: source)
        let pending = harness.read(&tailer)
        #expect(!pending.failed)
        #expect(!pending.didReset)
        #expect(pending.bytesRead == remainder.count)
        #expect(tailer.offset == Int64(large.count - 1))
        #expect(harness.lines.isEmpty)
        #expect(harness.upserts.isEmpty)
        #expect(harness.parser.state.malformedLines == 0)
        #expect(tailer.oversizedLines == 0)

        try Self.append(Data([0x0A]) + after, to: source)
        let completed = harness.read(&tailer)
        #expect(!completed.failed)
        #expect(!completed.didReset)
        #expect(completed.bytesRead == 1 + after.count)
        #expect(tailer.offset == Int64(large.count + after.count))
        #expect(tailer.oversizedLines == 0)
        #expect(harness.lineSizes == [large.count - 1, after.count - 1])
        try Self.expectSemantics(harness, keys: ["large", "after"])
        #expect(harness.read(&tailer).bytesRead == 0)
        #expect(harness.upserts.count == 2)
        #expect(harness.lines.count == 2)
    }

    private static func expectSemantics(_ harness: Harness, keys: [String]) throws {
        #expect(harness.lines.count == keys.count)
        #expect(harness.upserts.map(\.record.key) == keys)
        #expect(harness.upserts.allSatisfy(\.isCompletion))
        #expect(harness.parser.state.malformedLines == 0)
        #expect(harness.parser.state.source == .claudeCode)
        #expect(harness.parser.state.phase == .idle)
        for (index, key) in keys.enumerated() {
            let seed = index + 1
            let line = try #require(harness.lines.dropFirst(index).first)
            let upsert = try #require(harness.upserts.dropFirst(index).first)
            let expected = TokenUsage(input: 31 * seed, cachedInput: 11 * seed,
                                      cacheWriteInput: 13 * seed, cacheWrite1hInput: 8 * seed,
                                      output: 19 * seed, reasoning: 3 * seed)
            #expect(line.messageId == key)
            #expect(line.model == "claude-opus")
            #expect(line.usage == expected)
            #expect(line.entrypointSource == .claudeCode)
            #expect(line.stopReason == .other)
            #expect(line.userTextTitleCandidate == nil)
            #expect(upsert.record.usage == expected)
            #expect(upsert.record.model == "claude-opus")
            #expect(upsert.record.source == .claudeCode)
            #expect(upsert.record.isFinal)
        }
    }

    /// Anonymous content only; no trailing whitespace is used for size padding.
    private static func record(id: String, seed: Int, bytes: Int? = nil,
                               shape: ContentShape = .plainText) throws -> Data {
        let contentStart: String
        let contentEnd: String
        switch shape {
        case .plainText:
            contentStart = "\""
            contentEnd = "\""
        case .structuredToolResult:
            contentStart = #"[{"type":"tool_result","tool_use_id":"anonymous-tool","content":[{"type":"text","text":"escaped: \" \\ \n \u263a "#
            contentEnd = #""}]},{"type":"text","text":"anonymous suffix"}]"#
        }
        let start = #"{"type":"assistant","entrypoint":"cli","sessionId":"anonymous-session","timestamp":"2026-11-26T10:00:0\#(seed)Z","message":{"id":"\#(id)","model":"claude-opus","content":\#(contentStart)"#
        let end = #"\#(contentEnd),"stop_reason":"end_turn","usage":{"input_tokens":\#(7 * seed),"output_tokens":\#(19 * seed),"cache_read_input_tokens":\#(11 * seed),"cache_creation_input_tokens":\#(13 * seed),"cache_creation":{"ephemeral_5m_input_tokens":\#(5 * seed),"ephemeral_1h_input_tokens":\#(8 * seed)},"output_tokens_details":{"thinking_tokens":\#(3 * seed)}}}}"# + "\n"
        let overhead = start.utf8.count + end.utf8.count
        let target = bytes ?? overhead + 16
        #expect(target >= overhead)
        var result = Data(start.utf8)
        result.append(Data(repeating: 0x61, count: max(0, target - overhead)))
        result.append(Data(end.utf8))
        #expect(result.count == target)
        _ = try JSONSerialization.jsonObject(with: result)
        return result
    }

    private static func append(_ data: Data, to source: URL) throws {
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
