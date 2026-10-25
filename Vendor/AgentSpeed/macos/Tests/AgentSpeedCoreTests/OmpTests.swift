import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("omp")
struct OmpTests {
    static var ompFixtures: [String: Any] {
        get throws { try #require(try Fixtures.json("parser-expected.json")["omp"] as? [String: Any]) }
    }

    /// A deduper after reading every file of `order` before `file` from the start, as the reference does.
    static func deduper(before file: String) throws -> Deduper {
        let order = try #require(try Fixtures.json("parser-expected.json")["order"] as? [String])
        var deduper = Deduper()
        for (index, relative) in order.enumerated() {
            if relative == file { break }
            var parser = ParserFixtureTests.parser(for: relative, fileID: FileID(index))
            try GeminiTests.feed(relative, into: &parser, deduper: &deduper)
        }
        return deduper
    }

    // MARK: - Fixtures

    @Test func fixturesMatchTheReference() throws {
        let (expected, results) = try ParserFixtureTests.runFixtures()
        let files = try #require(expected["files"] as? [String: [String: Any]])
        let omp = files.filter { $0.key.hasPrefix("omp/") }
        #expect(omp.count == 12)
        for (relative, spec) in omp {
            let summary = Self.summary(try #require(results[relative]))
            for (field, wanted) in spec where field != "parentFile" {
                let actual = summary[field] ?? NSNull()
                #expect((actual as AnyObject).isEqual(wanted), "\(relative) \(field): \(actual)")
            }
        }
    }

    /// The fields of `parser-expected.json`, with nil as `NSNull`.
    static func summary(_ result: ParserFixtureTests.FileResult) -> [String: Any] {
        func value(_ value: Any?) -> Any { value ?? NSNull() }
        let state = result.state
        let responses: [[String: Any]] = result.responses.map { response in
            [
                "key": response.key, "startMs": value(response.startMs), "endMs": response.endMs,
                "input": response.usage.input, "cachedInput": response.usage.cachedInput,
                "cacheWriteInput": response.usage.cacheWriteInput, "cacheWrite1hInput": response.usage.cacheWrite1hInput,
                "output": response.usage.output, "reasoning": response.usage.reasoning, "model": value(response.model),
                "provider": value(response.provider), "fast": response.fast, "final": response.isFinal,
            ]
        }
        return [
            "source": state.source.rawValue, "project": value(state.project), "model": value(state.model),
            "isSubagent": state.isSubagent, "phase": state.phase.rawValue, "inFlightStartMs": value(state.inFlightStartMs),
            "lastLineMs": value(state.lastLineMs), "malformedLines": state.malformedLines, "responses": responses,
        ]
    }

    @Test func tracesMatchPhaseAfterEveryCheckpoint() throws {
        let traces = try #require(try Self.ompFixtures["traces"] as? [[String: Any]])
        #expect(traces.count >= 70)
        for trace in traces {
            let file = try #require(trace.string("file"))
            let afterLine = trace.int("afterLine")
            var deduper = try Self.deduper(before: file)
            var parser = ParserFixtureTests.parser(for: file, fileID: 999)
            try GeminiTests.feed(file, into: &parser, deduper: &deduper, lines: afterLine)
            #expect(parser.state.phase.rawValue == trace.string("phase"), "\(file) line \(afterLine) phase")
            #expect(parser.state.inFlightStartMs == trace.int64("inFlightStartMs"), "\(file) line \(afterLine) inFlightStartMs")
        }
    }

    @Test func tailReadsTakeTheHeaderFirst() throws {
        let reads = try #require(try Self.ompFixtures["tailReads"] as? [[String: Any]])
        #expect(!reads.isEmpty)
        for read in reads {
            let file = try #require(read.string("file"))
            let offset = try #require(read.int64("offset"))
            var deduper = try Self.deduper(before: file)
            var parser = ParserFixtureTests.parser(for: file, fileID: 999)
            var keys: [String] = []
            var reader = TranscriptReader(path: Fixtures.root.appendingPathComponent(file).path, start: .end(offset),
                                          readsHeaderFirst: true)
            let result = reader.read { bytes in
                parser.consume(rawLine: bytes, deduper: &deduper) { upsert in
                    if !keys.contains(upsert.record.key) { keys.append(upsert.record.key) }
                }
            }
            #expect(!result.failed)
            #expect(parser.state.project == read.string("project"), "\(file) project")
            #expect(parser.state.phase.rawValue == read.string("phase"), "\(file) phase")
            #expect(parser.state.inFlightStartMs == read.int64("inFlightStartMs"), "\(file) inFlightStartMs")
            #expect(parser.state.lastLineMs == read.int64("lastLineMs"), "\(file) lastLineMs")
            #expect(keys == read["responseKeys"] as? [String], "\(file) responseKeys")
        }
    }

    @Test func discoveryFindsOnlySessionFiles() throws {
        let wanted = try #require(try Self.ompFixtures["discover"] as? [String])
        let roots = ParserFixtureTests.ompRoots
        #expect(roots.map { String($0.dropFirst(Fixtures.root.path.count)) } == ["/omp/agent/sessions", "/omp/profiles/work/agent/sessions"])
        let prefix = Fixtures.root.path + "/"
        var found: [String] = []
        for root in roots {
            var index = DirectoryIndex(root: root, names: .ompSession)
            found += index.scan().map { String($0.dropFirst(prefix.count)) }
        }
        #expect(found.sorted() == wanted)
    }

    @Test func rootsFollowTheEnvironment() throws {
        let directory = try TempDirectory()
        let home = directory.file("home")
        let xdg = directory.file("xdg")
        for folder in [".omp/profiles/work", ".omp/profiles/play", ".pi-alt/profiles/solo"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for folder in ["omp/profiles/work", "omp/profiles/lab"] {
            try FileManager.default.createDirectory(at: xdg.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let omp = home.path + "/.omp"
        let alt = home.path + "/.pi-alt"
        let data = xdg.path + "/omp"
        let cases: [([String: String], [String])] = [
            ([:], [omp + "/agent/sessions", omp + "/profiles/play/agent/sessions", omp + "/profiles/work/agent/sessions"]),
            (["PI_CODING_AGENT_DIR": "/agent"],
             ["/agent/sessions", omp + "/profiles/play/agent/sessions", omp + "/profiles/work/agent/sessions"]),
            (["PI_CONFIG_DIR": ".pi-alt"], [alt + "/agent/sessions", alt + "/profiles/solo/agent/sessions"]),
            (["PI_CONFIG_DIR": "/.pi-alt"], [alt + "/agent/sessions", alt + "/profiles/solo/agent/sessions"]),
            (["XDG_DATA_HOME": xdg.path],
             [data + "/sessions", data + "/profiles/lab/sessions", omp + "/profiles/play/agent/sessions",
              data + "/profiles/work/sessions"]),
        ]
        for (environment, wanted) in cases {
            #expect(TranscriptLocations.ompRoots(environment: environment, home: home).map(\.path) == wanted, "\(environment)")
        }
    }

    // MARK: - Lines

    struct Phase: Equatable, CustomStringConvertible {
        var phase: AgentPhase
        var inFlightStartMs: Int64?

        init(_ phase: AgentPhase, _ inFlightStartMs: Int64? = nil) {
            self.phase = phase
            self.inFlightStartMs = inFlightStartMs
        }

        init(_ state: AgentState) {
            self.init(state.phase, state.inFlightStartMs)
        }

        var description: String { "\(phase.rawValue) \(inFlightStartMs.map(String.init) ?? "nil")" }
    }

    static let root = "/Users/dev/.omp/agent/sessions"
    static let mainPath = root + "/-projects-nova/2026-10-20T10-00-00-000Z_s1.jsonl"
    /// The header time, 2026-10-20T10:00:00Z.
    static let t0: Int64 = 1_792_490_400_000

    static func iso(_ ms: Int64) -> String {
        let day = ms - 1_792_454_400_000
        return String(format: "2026-10-20T%02lld:%02lld:%02lld.%03lldZ", day / 3_600_000, day / 60_000 % 60, day / 1000 % 60, day % 1000)
    }

    static func header(at ms: Int64 = t0, cwd: String = "/Users/dev/projects/nova") -> String {
        #"{"type":"session","version":3,"id":"s1","timestamp":"\#(iso(ms))","cwd":"\#(cwd)"}"#
    }

    static func entry(_ id: String, at ms: Int64, type: String = "message", _ members: String) -> String {
        #"{"type":"\#(type)","id":"\#(id)","parentId":null,"timestamp":"\#(iso(ms))",\#(members)}"#
    }

    static func user(_ id: String, at ms: Int64) -> String {
        entry(id, at: ms, #""message":{"role":"user","content":[{"type":"text","text":"hi"}],"timestamp":\#(ms)}"#)
    }

    /// An assistant entry; `fields` are further members of its message.
    static func assistant(
        _ id: String,
        at ms: Int64,
        _ fields: String = #""stopReason":"stop""#,
        usage: String = #"{"input":10,"output":20,"cacheRead":5,"cacheWrite":1}"#
    ) -> String {
        entry(id, at: ms, #""message":{"role":"assistant","api":"a","provider":"p","model":"m1","usage":\#(usage),\#(fields)}"#)
    }

    static func toolResult(_ id: String, at ms: Int64, _ fields: String) -> String {
        entry(id, at: ms, #""message":{"role":"toolResult","content":[{"type":"text","text":"ok"}],\#(fields)}"#)
    }

    @discardableResult
    static func feed(_ lines: [String], into parser: inout OmpParser, deduper: inout Deduper) -> [ResponseUpsert] {
        var upserts: [ResponseUpsert] = []
        for line in lines {
            Array(line.utf8).withUnsafeBytes { bytes in
                parser.consume(OmpLineExtractor.extract(bytes), deduper: &deduper) { upserts.append($0) }
            }
        }
        return upserts
    }

    static func run(_ lines: [String]) -> (state: AgentState, upserts: [ResponseUpsert]) {
        var parser = OmpParser(agentId: mainPath, fileID: 1, root: root)
        var deduper = Deduper()
        let upserts = feed(lines, into: &parser, deduper: &deduper)
        return (parser.state, upserts)
    }

    // MARK: - Malformed data and edge cases

    @Test func malformedAndIgnoredLines() {
        let (state, upserts) = Self.run([
            Self.header(),
            "[1,2]", #""text""#, "42", "null",
            #"{"type":"message","#,
            Self.user("u1", at: Self.t0 + 1000) + " trailing",
            "", "   ", "\u{0B}\u{0C} \r",
            "{}",
            #"{"type":"title","v":1,"id":"t","timestamp":"\#(Self.iso(Self.t0 + 9000))","title":"x","pad":"   "}"#,
            #"{"type":7,"id":"n","timestamp":"\#(Self.iso(Self.t0 + 500))"}"#,
        ])
        #expect(state.malformedLines == 6)
        #expect(state.lastLineMs == Self.t0 + 500, "an entry of an unknown type only counts for lastLineMs")
        #expect(state.phase == .idle)
        #expect(state.project == "nova")
        #expect(state.source == .omp)
        #expect(upserts.isEmpty)
    }

    @Test func entriesNeedAStringIdAndATimestamp() {
        let at = Self.iso(Self.t0 + 1000)
        let (state, _) = Self.run([
            Self.header(),
            #"{"type":"message","timestamp":"\#(at)","message":{"role":"user"}}"#,
            #"{"type":"message","id":7,"timestamp":"\#(at)","message":{"role":"user"}}"#,
            #"{"type":"message","id":"u1","timestamp":"yesterday","message":{"role":"user"}}"#,
            #"{"type":"message","id":"u1","message":{"role":"user"}}"#,
            #"{"type":"message","id":"u1","timestamp":1792490401000,"message":{"role":"user"}}"#,
        ])
        #expect(state.phase == .idle)
        #expect(state.lastLineMs == Self.t0)

        let (later, _) = Self.run([Self.header(), Self.user("u1", at: Self.t0 + 6000)])
        #expect(later.phase == .generating)
        #expect(later.inFlightStartMs == Self.t0 + 6000)
        #expect(later.lastLineMs == Self.t0 + 6000)
    }

    @Test func onlyTheFirstHeaderCountsAndEarlierLinesAreIgnored() {
        var parser = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        var deduper = Deduper()
        var upserts = Self.feed([Self.user("u0", at: Self.t0 + 100), Self.assistant("a0", at: Self.t0 + 200)],
                                into: &parser, deduper: &deduper)
        #expect(parser.state.lastLineMs == nil)
        #expect(parser.state.project == nil)
        #expect(parser.state.phase == .idle)
        #expect(parser.state.thread == SessionThread(id: nil, parentId: nil, createdMs: 0))

        upserts += Self.feed([
            Self.header(),
            Self.user("u1", at: Self.t0 + 2000),
            Self.header(at: Self.t0 + 3000, cwd: #"C:\\work\\other"#),
        ], into: &parser, deduper: &deduper)
        #expect(upserts.isEmpty)
        #expect(parser.state.project == "nova")
        #expect(parser.state.thread == SessionThread(id: "s1", parentId: nil, createdMs: Self.t0))
        #expect(parser.state.lastLineMs == Self.t0 + 2000)
        #expect(parser.state.phase == .generating)

        let (windows, _) = Self.run([Self.header(cwd: #"C:\\work\\pad\\"#)])
        #expect(windows.project == "pad", "cwd splits on both separators")
        let (rootOnly, _) = Self.run([Self.header(cwd: "/")])
        #expect(rootOnly.project == nil)
    }

    @Test func copiedHistoryIsIgnoredCompletely() {
        var parser = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        var deduper = Deduper()
        let upserts = Self.feed([
            Self.header(at: Self.t0 + 10_000),
            Self.assistant("c1", at: Self.t0 + 7999, #""stopReason":"stop","timestamp":\#(Self.t0 + 7000)"#),
            Self.assistant("c2", at: Self.t0 + 8000, #""stopReason":"stop","timestamp":\#(Self.t0 + 7500)"#),
        ], into: &parser, deduper: &deduper)
        #expect(upserts.map(\.record.key) == ["omp:c2:\(Self.t0 + 7500)"])
        #expect(!deduper.contains("omp:c1:\(Self.t0 + 7000)"))
        #expect(parser.state.lastLineMs == Self.t0 + 10_000)

        let headless = #"{"type":"session","id":"s2","cwd":"/p/q"}"#
        let (state, without) = Self.run([headless, Self.assistant("c3", at: Self.t0 - 3_600_000)])
        #expect(without.count == 1, "a header without a timestamp copies nothing")
        #expect(state.lastLineMs == Self.t0 - 3_600_000)
        #expect(state.thread?.createdMs == 0)
    }

    @Test func zeroUsageChangesOnlyThePhase() {
        var parser = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        var deduper = Deduper()
        let upserts = Self.feed([
            Self.header(),
            Self.user("u1", at: Self.t0 + 1000),
            Self.assistant("z1", at: Self.t0 + 2000, #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1"}]"#,
                           usage: #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoningTokens":9}"#),
        ], into: &parser, deduper: &deduper)
        #expect(upserts.isEmpty)
        #expect(parser.state.phase == .tools)
        #expect(parser.state.model == nil)
        #expect(!deduper.contains("omp:z1:\(Self.t0 + 2000)"))

        let (state, none) = Self.run([
            Self.header(),
            Self.assistant("z2", at: Self.t0 + 3000, usage: #"{"input":0.5,"output":true,"cacheRead":-3,"cacheWrite":"9"}"#),
        ])
        #expect(none.isEmpty, "values that truncate to 0 are not usage")
        #expect(state.phase == .idle)
    }

    @Test func tokensFollowPythonNumbers() throws {
        let (_, upserts) = Self.run([
            Self.header(),
            Self.assistant("k1", at: Self.t0 + 1000, usage:
                #"{"input":-5,"output":12.9,"cacheRead":true,"cacheWrite":"7","reasoningTokens":3.99,"totalTokens":999}"#),
            Self.assistant("k2", at: Self.t0 + 2000, usage:
                #"{"input":1E2,"output":2.5e3,"cacheRead":-0.0,"cacheWrite":7.0,"reasoningTokens":null,"output":2.5e1}"#),
            Self.assistant("k3", at: Self.t0 + 3000, usage: #"{"output":1e400,"input":99999999999999999999999}"#),
        ])
        try #require(upserts.count == 3)
        #expect(upserts[0].record.usage == TokenUsage(input: 0, cachedInput: 0, cacheWriteInput: 0, output: 12, reasoning: 3))
        #expect(upserts[1].record.usage == TokenUsage(input: 107, cachedInput: 0, cacheWriteInput: 7, output: 25, reasoning: 0),
                "a repeated member counts once, the last one")
        #expect(upserts[2].record.usage.output == Int(TokenCount.ceiling))
        #expect(upserts[2].record.usage.input == Int(TokenCount.ceiling))
    }

    @Test func timingFallsBackLikeTheReference() throws {
        let t0 = Self.t0
        let (_, upserts) = Self.run([
            Self.header(),
            Self.assistant("a1", at: t0 + 4000, #""stopReason":"stop","timestamp":1792490401000.9,"duration":2500.999"#),
            Self.assistant("a2", at: t0 + 8000, #""stopReason":"stop","timestamp":\#(t0 + 5000),"duration":-0.3,"completedAt":1792490407000.6"#),
            Self.assistant("a3", at: t0 + 10_000, #""stopReason":"stop","timestamp":\#(t0 + 9000),"duration":-0.3"#),
            Self.assistant("a4", at: t0 + 12_000, #""stopReason":"stop","timestamp":\#(t0 + 11_000),"duration":-0.0"#),
            Self.assistant("a5", at: t0 + 13_000, #""stopReason":"stop","timestamp":0,"duration":500"#),
            Self.assistant("a6", at: t0 + 14_000, #""stopReason":"stop","timestamp":0.5,"duration":700.2"#),
            Self.assistant("a7", at: t0 + 15_000, #""stopReason":"stop","completedAt":0.5"#),
            Self.assistant("a8", at: t0 + 16_000, #""stopReason":"stop","timestamp":true,"completedAt":0,"duration":5"#),
            Self.assistant("a9", at: t0 + 17_000, #""stopReason":"stop","timestamp":-5,"completedAt":"1792490418000""#),
            Self.assistant("a10", at: t0 + 18_000, #""stopReason":"stop","timestamp":1e400,"duration":1e400,"completedAt":-1e400"#),
            Self.assistant("a11", at: t0 + 19_000, #""stopReason":"stop","timestamp":\#(t0 + 18_500),"duration":1e400,"completedAt":\#(t0 + 18_900)"#),
        ])
        let timings = upserts.map { [$0.record.key, $0.record.startMs.map(String.init) ?? "nil", String($0.record.endMs)] }
        let wanted: [[String]] = [
            ["omp:a1:\(t0 + 1000)", "\(t0 + 1000)", "\(t0 + 3500)"],
            ["omp:a2:\(t0 + 5000)", "\(t0 + 5000)", "\(t0 + 7000)"],
            ["omp:a3:\(t0 + 9000)", "\(t0 + 9000)", "\(t0 + 10_000)"],
            ["omp:a4:\(t0 + 11_000)", "\(t0 + 11_000)", "\(t0 + 11_000)"],
            ["omp:a5:\(t0 + 13_000)", "nil", "\(t0 + 13_000)"],
            ["omp:a6:0", "0", "700"],
            ["omp:a7:\(t0 + 15_000)", "nil", "0"],
            ["omp:a8:\(t0 + 16_000)", "nil", "\(t0 + 16_000)"],
            ["omp:a9:\(t0 + 17_000)", "nil", "\(t0 + 17_000)"],
            ["omp:a10:\(t0 + 18_000)", "nil", "\(t0 + 18_000)"],
            ["omp:a11:\(t0 + 18_500)", "\(t0 + 18_500)", "\(t0 + 18_900)"],
        ]
        #expect(timings == wanted)
        #expect(upserts.allSatisfy { $0.isCompletion && $0.record.isFinal && $0.record.source == .omp })
        #expect(upserts.first?.record.agentId == Self.mainPath)
    }

    @Test func stopReasonsDecideThePhase() {
        let t0 = Self.t0
        let call = #""content":[{"type":"toolCall","id":"c1"}],"timestamp":\#(t0 + 100),"duration":50"#
        let cases: [(String, AgentPhase, Bool)] = [
            (call, .idle, false),
            (#""stopReason":5,"# + call, .idle, false),
            (#""stopReason":"error","# + call, .idle, false),
            (#""stopReason":"aborted","# + call, .idle, false),
            (#""stopReason":"toolUse","# + call, .tools, true),
            (#""stopReason":"stop","# + call, .tools, true),
            (#""stopReason":"length","# + call, .tools, true),
            (#""stopReason":"refusal","# + call, .idle, true),
            (#""stopReason":"toolUse","timestamp":\#(t0 + 100)"#, .idle, true),
        ]
        for (fields, phase, timed) in cases {
            let (state, upserts) = Self.run([Self.header(), Self.user("u1", at: t0 + 50), Self.assistant("a1", at: t0 + 1000, fields)])
            #expect(state.phase == phase, "\(fields)")
            #expect(state.inFlightStartMs == nil, "\(fields)")
            #expect(upserts.first?.record.startMs == (timed ? t0 + 100 : nil), "\(fields) startMs")
            #expect(state.model == "m1", "\(fields)")
        }
    }

    @Test func pauseTurnSamplesAgain() {
        let t0 = Self.t0
        let timing = #""timestamp":\#(t0 + 1000),"duration":2000.4"#
        let cases: [(String, AgentPhase, Int64?)] = [
            (#""stopReason":"stop","stopDetails":{"type":"pause_turn"},"# + timing, .generating, t0 + 3000),
            (#""stopReason":"toolUse","stopDetails":{"type":"pause_turn"},"# + timing, .idle, nil),
            (#""stopReason":"stop","stopDetails":{"type":"pause_turn"},"content":[{"type":"toolCall","id":"c"}],"# + timing, .tools, nil),
            (#""stopReason":"stop","stopDetails":"pause_turn","# + timing, .idle, nil),
            (#""stopReason":"stop","stopDetails":{"type":"pause_turn"},"stopDetails":{},"# + timing, .idle, nil),
        ]
        for (fields, phase, inFlight) in cases {
            let (state, _) = Self.run([Self.header(), Self.assistant("a1", at: t0 + 3100, fields)])
            #expect(state.phase == phase, "\(fields)")
            #expect(state.inFlightStartMs == inFlight, "\(fields)")
        }
    }

    @Test func toolResultsAndYield() {
        let t0 = Self.t0
        var parser = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        var deduper = Deduper()
        func step(_ line: String) -> Phase {
            Self.feed([line], into: &parser, deduper: &deduper)
            return Phase(parser.state)
        }
        _ = step(Self.header())
        let calls = #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1"},{"type":"toolCall","id":"c2"},{"type":"text","id":"c9"}]"#
        #expect(step(Self.assistant("a1", at: t0 + 1000, calls)) == Phase(.tools))
        #expect(step(Self.toolResult("r1", at: t0 + 1100, #""toolCallId":"c1","toolName":"bash""#)) == Phase(.tools))
        #expect(step(Self.toolResult("r2", at: t0 + 1200, #""toolCallId":"c9","toolName":"bash""#)) == Phase(.tools))
        #expect(step(Self.toolResult("r3", at: t0 + 1250, #""toolCallId":7"#)) == Phase(.tools))
        #expect(step(Self.toolResult("r4", at: t0 + 1300, #""toolCallId":"c2","toolName":"bash""#)) == Phase(.generating, t0 + 1300))
        #expect(step(Self.toolResult("r5", at: t0 + 1400, #""toolCallId":"c2""#)) == Phase(.generating, t0 + 1300))

        #expect(step(Self.assistant("a2", at: t0 + 2000, #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c3"}]"#)) == Phase(.tools))
        #expect(step(Self.toolResult("r6", at: t0 + 2100, #""toolCallId":"y1","toolName":"yield","isError":false"#)) == Phase(.idle))

        #expect(step(Self.assistant("a3", at: t0 + 3000, #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c4"}]"#)) == Phase(.tools))
        #expect(step(Self.toolResult("r7", at: t0 + 3100, #""toolCallId":"y2","toolName":"yield","isError":true"#)) == Phase(.tools))
        #expect(step(Self.toolResult("r8", at: t0 + 3200, #""toolCallId":"c4","toolName":"yield","isError":true"#)) == Phase(.generating, t0 + 3200))
        #expect(step(Self.toolResult("r9", at: t0 + 3300, #""toolCallId":"c5","toolName":"yield","isError":1"#)) == Phase(.idle))
        #expect(step(Self.toolResult("r10", at: t0 + 3400, #""toolCallId":"c5""#)) == Phase(.idle))

        #expect(step(Self.assistant("a4", at: t0 + 4000, #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c6"}]"#)) == Phase(.tools))
        #expect(step(Self.entry("d1", at: t0 + 4100, #""message":{"role":"developer"}"#)) == Phase(.generating, t0 + 4100))
        #expect(step(Self.toolResult("r11", at: t0 + 4200, #""toolCallId":"c6""#)) == Phase(.generating, t0 + 4100),
                "a tool result outside a tool phase changes nothing")
        #expect(step(Self.entry("e1", at: t0 + 5000, type: "custom", #""customType":"note""#)) == Phase(.generating, t0 + 4100))
        #expect(step(Self.entry("e2", at: t0 + 5100, type: "custom", #""customType":"session_exit""#)) == Phase(.idle))
        #expect(step(Self.entry("b1", at: t0 + 6000, #""message":{"role":"bashExecution"}"#)) == Phase(.idle))
        #expect(parser.state.lastLineMs == t0 + 6000)
    }

    @Test func modelUsageCountsSideCalls() throws {
        let t0 = Self.t0
        let side = #""purpose":"memory","role":"smol","api":"openai-responses","provider":"openai","model":"side-model""#
        var parser = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        var deduper = Deduper()
        let upserts = Self.feed([
            Self.header(),
            Self.assistant("a1", at: t0 + 1000),
            Self.user("u1", at: t0 + 2000),
            Self.entry("m1", at: t0 + 3000, type: "model_usage",
                       side + #","usage":{"input":100,"output":10,"cacheRead":3,"reasoningTokens":4},"stopReason":"error""#),
            Self.entry("m2", at: t0 + 3100, type: "model_usage", #""api":"a","model":"x","usage":{"input":5}"#),
            Self.entry("m3", at: t0 + 3200, type: "model_usage", side + #","usage":{"input":0,"output":0}"#),
            Self.entry("m4", at: t0 + 3300, type: "model_usage", side + #","usage":[1]"#),
        ], into: &parser, deduper: &deduper)
        try #require(upserts.count == 2)
        let record = upserts[1].record
        #expect(record.key == "omp:m1:\(t0 + 3000)")
        #expect(record.startMs == nil)
        #expect(record.endMs == t0 + 3000)
        #expect(record.model == "side-model")
        #expect(record.usage == TokenUsage(input: 103, cachedInput: 3, cacheWriteInput: 0, output: 10, reasoning: 4))
        #expect(upserts[1].isCompletion)
        #expect(parser.state.model == "m1", "side calls never set the agent model")
        #expect(parser.state.phase == .generating)
        #expect(parser.state.inFlightStartMs == t0 + 2000)
        #expect(parser.state.lastLineMs == t0 + 3300)
        #expect(!deduper.contains("omp:m3:\(t0 + 3200)"))
    }

    @Test func keysOwnedByAnotherFileAreSkipped() {
        let t0 = Self.t0
        let original = Self.assistant("a1", at: t0 + 1000, #""stopReason":"stop","timestamp":\#(t0 + 500),"duration":400"#)
        var deduper = Deduper()
        var first = OmpParser(agentId: Self.mainPath, fileID: 1, root: Self.root)
        #expect(Self.feed([Self.header(), original], into: &first, deduper: &deduper).count == 1)

        var fork = OmpParser(agentId: Self.root + "/-projects-nova/fork.jsonl", fileID: 2, root: Self.root)
        let copied = Self.assistant("a1", at: t0 + 1000, #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c"}],"timestamp":\#(t0 + 500)"#,
                                    usage: #"{"input":0}"#)
        let upserts = Self.feed([Self.header(at: t0 - 1000), Self.user("u1", at: t0 + 200), copied, original],
                                into: &fork, deduper: &deduper)
        #expect(upserts.isEmpty)
        #expect(fork.state.phase == .generating, "an owned key changes no phase, even without usage")
        #expect(fork.state.inFlightStartMs == t0 + 200)
        #expect(fork.state.lastLineMs == t0 + 1000)
        #expect(fork.state.model == nil)
    }

    @Test func repeatsInTheSameFileAreUpdates() throws {
        let t0 = Self.t0
        let fields = #""stopReason":"stop","timestamp":\#(t0 + 500)"#
        let (state, upserts) = Self.run([
            Self.header(),
            Self.assistant("a1", at: t0 + 1000, fields, usage: #"{"input":0}"#),
            Self.assistant("a1", at: t0 + 1000, fields, usage: #"{"input":1,"output":2}"#),
            Self.assistant("a1", at: t0 + 1200, fields, usage: #"{"input":1,"output":9}"#),
        ])
        try #require(upserts.count == 2)
        #expect(upserts.map(\.isCompletion) == [true, false])
        #expect(upserts[1].record.usage.output == 9)
        #expect(upserts[1].record.endMs == t0 + 1200)
        #expect(state.lastLineMs == t0 + 1200)
    }

    @Test func repeatedMembersKeepTheLastValue() throws {
        let t0 = Self.t0
        let user = Self.user("u1", at: t0 + 100)
        /// The phase and the number of responses after `line`.
        func outcome(after line: String) -> String {
            let (state, upserts) = Self.run([Self.header(), user, line])
            return "\(state.phase.rawValue) \(upserts.count)"
        }
        #expect(outcome(after: Self.assistant("a1", at: t0 + 1000,
            #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1"}],"content":[]"#)) == "idle 1")
        #expect(outcome(after: Self.assistant("a2", at: t0 + 1000, #""stopReason":"toolUse","usage":"x""#)) == "generating 0",
                "a call that fails the guard changes nothing")
        #expect(outcome(after: Self.assistant("a3", at: t0 + 1000,
            #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","type":"text"}]"#)) == "idle 1")
        #expect(outcome(after: Self.assistant("a4", at: t0 + 1000,
            #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","id":2}]"#)) == "idle 1")
        #expect(outcome(after: Self.assistant("a5", at: t0 + 1000, #""stopReason":"stop","stopReason":3"#)) == "idle 1")
        #expect(outcome(after: Self.assistant("a6", at: t0 + 1000, #""stopReason":"stop","model":null"#)) == "generating 0")
        #expect(outcome(after: Self.entry("x1", at: t0 + 1000,
            #""message":{"role":"assistant","api":"a","provider":"p","model":"m","usage":{"output":1},"stopReason":"stop"},"message":7"#)) == "generating 0")
        #expect(outcome(after: #"{"type":"message","id":"x2","type":"custom","customType":"session_exit","timestamp":"\#(Self.iso(t0 + 1000))"}"#) == "idle 0")
        #expect(outcome(after: #"{"type":"session","id":"x3","type":"message","timestamp":"\#(Self.iso(t0 + 1000))","message":{"role":"assistant","role":"user"}}"#) == "generating 0")

        let (state, upserts) = Self.run([
            Self.header(),
            Self.entry("x4", at: t0 + 1000, #""id":"x5","message":{"role":"assistant","api":"a","provider":"p","model":"m","model":"n","usage":{"output":1},"stopReason":"stop","timestamp":5,"timestamp":\#(t0 + 900)}"#),
        ])
        #expect(upserts.map(\.record.key) == ["omp:x5:\(t0 + 900)"])
        #expect(state.model == "n")
    }

    @Test func subagentsFollowTheirFolder() {
        let root = Self.root
        let main = root + "/-projects-pulsar/2026-10-20T10-50-00-000Z_s1.jsonl"
        let task = root + "/-projects-pulsar/2026-10-20T10-50-00-000Z_s1/ScanCallSites.jsonl"
        let nested = root + "/-projects-pulsar/2026-10-20T10-50-00-000Z_s1/ScanCallSites/VerifyImports.jsonl"
        let cases: [(String, String?, String?)] = [
            (main, root, nil),
            (task, root, root + "/-projects-pulsar/2026-10-20T10-50-00-000Z_s1.jsonl"),
            (nested, root + "/", root + "/-projects-pulsar/2026-10-20T10-50-00-000Z_s1/ScanCallSites.jsonl"),
            (task, nil, nil),
            (task, "", nil),
            (root + #"/-projects-pulsar/odd\name.jsonl"#, root, root + "/-projects-pulsar.jsonl"),
            ("/elsewhere/s.jsonl", root, "/elsewhere.jsonl"),
        ]
        for (path, root, parent) in cases {
            let parser = OmpParser(agentId: path, fileID: 1, root: root)
            #expect(parser.state.isSubagent == (parent != nil), "\(path) under \(root ?? "nil")")
            #expect(parser.state.thread == SessionThread(id: nil, parentId: parent, createdMs: 0), "\(path)")
            #expect(parser.state.source == .omp)
        }
    }

    // MARK: - Header lookup

    @Test func headerIsOneOfTheFirstTwoLines() throws {
        let directory = try TempDirectory()
        let title = #"{"type":"title","v":1,"title":"T","pad":""# + String(repeating: " ", count: 200) + #""}"#
        let header = Self.header()
        let entry = Self.user("u1", at: Self.t0 + 1000)
        func lookUp(_ text: String, maxLineBytes: Int = FileTailer.defaultMaxLineBytes) throws -> String? {
            try directory.write("s.jsonl", text)
            return OmpHeader.headerLine(atPath: directory.file("s.jsonl").path, maxLineBytes: maxLineBytes)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(try lookUp(title + "\n" + header + "\n" + entry + "\n") == header)
        #expect(try lookUp(header + "\r\n" + entry + "\n") == header + "\r")
        #expect(try lookUp(entry + "\n" + header + "\n") == header)
        #expect(try lookUp(title + "\n" + entry + "\n" + header + "\n") == nil, "a third line is never read")
        #expect(try lookUp("\n" + header + "\n") == header)
        #expect(try lookUp(title + "\n" + header) == header, "an unterminated line at the end counts")
        #expect(try lookUp(#"{"type":"session","# + "\n" + header + "\n") == header)
        #expect(try lookUp(title + "\n" + header + "\n", maxLineBytes: 128) == nil, "a long line counts as several")
        #expect(try lookUp(String(repeating: " ", count: 150) + header + "\n", maxLineBytes: 150) == header)
        #expect(try lookUp(title + "\n" + header + "\n", maxLineBytes: title.utf8.count + 1) == header)
        #expect(try lookUp("") == nil)
        #expect(OmpHeader.headerLine(atPath: directory.file("missing.jsonl").path, maxLineBytes: 1024) == nil)

        try directory.write("real.jsonl", header + "\n")
        try FileManager.default.createSymbolicLink(at: directory.file("link.jsonl"), withDestinationURL: directory.file("real.jsonl"))
        #expect(OmpHeader.headerLine(atPath: directory.file("link.jsonl").path, maxLineBytes: 1024) == nil, "symlinks are not followed")
        #expect(OmpHeader.headerLine(atPath: directory.path, maxLineBytes: 1024) == nil)
    }

    // MARK: - Incremental reading

    @Test func appendedLinesCompleteOnce() throws {
        let t0 = Self.t0
        let directory = try TempDirectory()
        let relative = "sessions/-projects-nova/2026-10-20T10-00-00-000Z_s1.jsonl"
        try directory.write(relative, Self.header() + "\n" + Self.user("u1", at: t0 + 1000) + "\n")
        let path = directory.file(relative).path
        var parser = TranscriptParser(family: .omp, agentId: path, fileID: 1, root: directory.file("sessions").path)
        var reader = TranscriptReader(path: path)
        var deduper = Deduper()
        var upserts: [ResponseUpsert] = []
        func read() {
            _ = reader.read { bytes in parser.consume(rawLine: bytes, deduper: &deduper) { upserts.append($0) } }
        }

        read()
        #expect(parser.state.project == "nova")
        #expect(!parser.state.isSubagent)
        #expect(parser.state.phase == .generating)
        #expect(parser.state.inFlightStartMs == t0 + 1000)

        let calls = #""stopReason":"toolUse","content":[{"type":"toolCall","id":"c1"}],"timestamp":\#(t0 + 1005),"duration":2990.5"#
        try directory.append(relative, Self.assistant("a1", at: t0 + 4000, calls) + "\n")
        read()
        #expect(upserts.count == 1)
        #expect(upserts.last?.isCompletion == true)
        #expect(upserts.last?.record.startMs == t0 + 1005)
        #expect(upserts.last?.record.endMs == t0 + 3995)
        #expect(parser.state.phase == .tools)

        try directory.append(relative, Self.toolResult("r1", at: t0 + 4100, #""toolCallId":"c1""#) + "\n")
        read()
        #expect(parser.state.phase == .generating)
        #expect(parser.state.inFlightStartMs == t0 + 4100)

        let answer = Self.assistant("a2", at: t0 + 6000, #""stopReason":"stop","timestamp":\#(t0 + 4105),"duration":1800"#)
        let split = answer.index(answer.startIndex, offsetBy: answer.count / 2)
        try directory.append(relative, String(answer[..<split]))
        read()
        #expect(upserts.count == 1, "an incomplete line waits for its newline")
        try directory.append(relative, String(answer[split...]) + "\n")
        read()
        #expect(upserts.count == 2)
        #expect(upserts.last?.isCompletion == true)
        #expect(upserts.last?.record.key == "omp:a2:\(t0 + 4105)")
        #expect(parser.state.phase == .idle)
        #expect(parser.state.model == "m1")
        read()
        #expect(upserts.count == 2)

        // A file that starts being read at its end still knows its header.
        let size = try #require(FileStat.lstat(path)?.size)
        var tail = TranscriptParser(family: .omp, agentId: path, fileID: 2, root: directory.file("sessions").path)
        var tailReader = TranscriptReader(path: path, start: .end(size), readsHeaderFirst: true)
        var tailDeduper = Deduper()
        var tailUpserts: [ResponseUpsert] = []
        func readTail() {
            _ = tailReader.read { bytes in tail.consume(rawLine: bytes, deduper: &tailDeduper) { tailUpserts.append($0) } }
        }
        readTail()
        #expect(tail.state.project == "nova")
        #expect(tail.state.lastLineMs == t0)
        #expect(tail.state.thread?.id == "s1")
        #expect(tailUpserts.isEmpty)
        try directory.append(relative, Self.user("u2", at: t0 + 7000) + "\n" + Self.assistant("a3", at: t0 + 9000) + "\n")
        readTail()
        #expect(tailUpserts.map(\.record.key) == ["omp:a3:\(t0 + 9000)"])
        #expect(tailUpserts.first?.isCompletion == true)
        #expect(tail.state.phase == .idle)
        #expect(tail.state.lastLineMs == t0 + 9000)
    }
}
