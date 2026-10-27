import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Gemini CLI")
struct GeminiTests {
    static var geminiFixtures: [String: Any] {
        get throws { try #require(try Fixtures.json("parser-expected.json")["gemini"] as? [String: Any]) }
    }

    /// Feeds a fixture file to a parser the way the reader does; `lines` limits a `.jsonl` file to its first physical lines.
    static func feed(_ relative: String, into parser: inout TranscriptParser, deduper: inout Deduper, lines: Int? = nil) throws {
        let url = Fixtures.root.appendingPathComponent(relative)
        if lines == nil, TranscriptReader.isFrameStream(url.path) || TranscriptReader.isCompressedStream(url.path)
            || TranscriptReader.isDocument(url.path) {
            var reader = TranscriptReader(path: url.path)
            _ = reader.read(onMalformed: { parser.noteMalformedLine() }) { bytes in
                parser.consume(rawLine: bytes, deduper: &deduper) { _ in }
            }
            return
        }
        let data = try Data(contentsOf: url)
        var count = 0
        forEachLine(in: data) { line in
            count += 1
            guard lines.map({ count <= $0 }) ?? true else { return }
            parser.consume(rawLine: line, deduper: &deduper) { _ in }
        }
    }

    @Test func discoveryFindsOnlySessionFiles() throws {
        let wanted = try #require(try Self.geminiFixtures["discover"] as? [String])
        var index = DirectoryIndex(root: Fixtures.root.appendingPathComponent("gemini/tmp").path, names: .geminiSession)
        let prefix = Fixtures.root.path + "/"
        let found = index.scan().map { String($0.dropFirst(prefix.count)) }.sorted()
        #expect(found == wanted)
    }

    @Test func tracesMatchPhaseAfterEveryCheckpoint() throws {
        let traces = try #require(try Self.geminiFixtures["traces"] as? [[String: Any]])
        let order = try #require(try Fixtures.json("parser-expected.json")["order"] as? [String])
        #expect(traces.count >= 20)
        for trace in traces {
            let file = try #require(trace.string("file"))
            let afterLine = trace.int("afterLine")
            var deduper = Deduper()
            for (index, relative) in order.enumerated() {
                if relative == file { break }
                var parser = TranscriptParser(family: ParserFixtureTests.family(of: relative),
                                              agentId: Fixtures.root.appendingPathComponent(relative).path, fileID: FileID(index))
                try Self.feed(relative, into: &parser, deduper: &deduper)
            }
            var parser = TranscriptParser(family: .gemini, agentId: Fixtures.root.appendingPathComponent(file).path, fileID: 999)
            try Self.feed(file, into: &parser, deduper: &deduper, lines: afterLine)
            #expect(parser.state.phase.rawValue == trace.string("phase"), "\(file) line \(afterLine) phase")
            #expect(parser.state.inFlightStartMs == trace.int64("inFlightStartMs"), "\(file) line \(afterLine) inFlightStartMs")
        }
    }

    @Test func rootsFollowGeminiCLIHome() {
        #expect(TranscriptLocations.geminiRoots(cliHome: "/x").map(\.path) == ["/x/.gemini/tmp", "/x/.cache/.gemini/tmp"])
        let defaults = MonitorConfiguration().resolvedRoots(for: .gemini)
        #expect(defaults.count == 2)
        let configured = MonitorConfiguration(geminiRoot: URL(fileURLWithPath: "/data/tmp/", isDirectory: true))
        #expect(configured.resolvedRoots(for: .gemini) == ["/data/tmp"], "a configured folder replaces both defaults")
        #expect(configured.requiresRescan(comparedTo: MonitorConfiguration()))
        #expect(AgentParents.sanitizedGeminiId("ab.c/d-e_f9é") == "ab_c_d-e_f9_")
    }

    @Test func sessionReadsFixturesAndLinksSubagents() throws {
        let directory = try TempDirectory()
        let mtimes = try #require(try Fixtures.json("parser-expected.json")["mtimes"] as? [String: NSNumber])
        for relative in try #require(try Self.geminiFixtures["discover"] as? [String]) {
            let bytes = try Data(contentsOf: Fixtures.root.appendingPathComponent(relative))
            let target = "cache/" + relative
            try directory.write(target, bytes: Array(bytes),
                                modified: mtimes[relative].map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
        for extra in ["gemini/tmp/nova/.project_root", "gemini/tmp/orbit/.project_root", "gemini/projects.json"] {
            try directory.write("cache/" + extra, bytes: Array(try Data(contentsOf: Fixtures.root.appendingPathComponent(extra))))
        }
        let configuration = MonitorConfiguration(enabledSources: [.gemini], geminiRoot: directory.file("cache/gemini/tmp"))
        let session = TranscriptSession(configuration: configuration)
        #expect(session.hasAvailableRoot)
        let fixtureDay = Clock.milliseconds(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_792_490_400)))
        let summary = session.seed(todayStartMs: fixtureDay)
        #expect(summary.filesRead == 5)
        #expect(session.responses.count == 9)
        let (output, _) = session.advance(nowMs: 1_792_492_340_000, todayStartMs: fixtureDay, emitsEvents: false)
        let agents = SnapshotBuilder.running(output, context: SnapshotContext(session: session, todayStartMs: fixtureDay)).agents
        let main = try #require(agents.firstIndex { $0.id.hasSuffix("session-2026-10-20T10-30-7f3a2b10.jsonl") })
        let children = agents.filter { $0.parentId == agents[main].id }
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.isSubagent && $0.project == "orbit" && $0.source == .gemini })
        let context = SnapshotContext(session: session, todayStartMs: fixtureDay)
        #expect(context.sources[.gemini]?.available == true)
        #expect(context.sources[.gemini]?.rootPath == directory.file("cache/gemini/tmp").path)
    }

    // MARK: - Legacy documents

    static func legacyDocument(_ responses: [(id: String, output: Int)], truncated: Bool = false) -> String {
        var messages: [String] = []
        for (index, response) in responses.enumerated() {
            let base = 1_792_490_400 + index * 60
            let user = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(base)))
            let reply = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(base + 5)))
            messages.append(#"{"id":"u\#(index)","timestamp":"\#(user)","type":"user","content":[{"text":"q"}]}"#)
            messages.append(#"{"id":"\#(response.id)","timestamp":"\#(reply)","type":"gemini","content":"done","tokens":{"input":10,"output":\#(response.output),"cached":0,"thoughts":5,"tool":1},"model":"gemini-2.5-pro"}"#)
        }
        let text = #"{"sessionId":"s-1","projectHash":"h","startTime":"2026-10-20T10:00:00.000Z","messages":[\#(messages.joined(separator: ","))]}"#
        return truncated ? String(text.dropLast(20)) : text
    }

    @Test func legacyDocumentIsReplayedOnEveryChange() throws {
        let directory = try TempDirectory()
        let relative = "tmp/proj/chats/session-2026-10-20T10-00-aaaa.json"
        try directory.write(relative, Self.legacyDocument([("g1", 100)]))
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.gemini], geminiRoot: directory.file("tmp")),
                                        clock: { 1_792_490_500_000 })
        _ = session.seed(todayStartMs: 0)
        #expect(session.responses.map(\.key) == ["g1"])
        #expect(session.responses.first?.usage == TokenUsage(input: 11, cachedInput: 0, cacheWriteInput: 0, output: 105, reasoning: 5))
        #expect(session.responses.first?.startMs == 1_792_490_400_000)

        // A rewrite with one more response: the earlier one is an update, the new one completes once.
        try directory.write(relative, Self.legacyDocument([("g1", 100), ("g2", 40)]))
        let canonical = try #require(realpath(directory.file(relative).path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(session.handleChanges(atCanonicalPaths: [canonical]))
        let (_, events) = session.advance(nowMs: 1_792_490_600_000, todayStartMs: 0, emitsEvents: true)
        let completed = events.compactMap { if case .responseCompleted(let summary) = $0 { summary.outputTokens } else { nil } }
        #expect(completed == [45])
        #expect(Set(session.responses.map(\.key)) == ["g1", "g2"])

        // Caught mid-write: one malformed line, the previous state stays.
        try directory.write(relative, Self.legacyDocument([("g1", 100), ("g2", 40), ("g3", 7)], truncated: true))
        session.handleChanges(atCanonicalPaths: [canonical])
        #expect(session.malformedLines == 1)
        #expect(Set(session.responses.map(\.key)) == ["g1", "g2"])
    }

    @Test func oversizedLegacyDocumentIsSkipped() throws {
        let directory = try TempDirectory()
        let path = directory.file("chats/big.json").path
        try directory.write("chats/big.json", Self.legacyDocument([("g1", 100)]))
        var reader = DocumentReader(path: path, maxBytes: 16)
        var documents = 0
        let result = reader.read(onReset: {}) { _ in documents += 1 }
        #expect(result.oversized)
        #expect(documents == 0)
        var small = DocumentReader(path: path)
        #expect(!small.read(onReset: {}) { _ in documents += 1 }.oversized)
        #expect(small.read(onReset: {}) { _ in documents += 1 }.bytesRead == 0, "unchanged documents are not read again")
        #expect(documents == 1)
    }
}
