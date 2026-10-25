import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Working directory metadata")
struct CwdPathTests {
    typealias PB = ProtobufEncoder

    static func claudeUser(_ ts: String, cwd: String?) -> String {
        let member = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return #"{"type":"user","entrypoint":"cli"\#(member),"message":{"role":"user","content":"go"},"timestamp":"\#(ts)"}"#
    }

    static func agent(_ agents: [AgentStatus], endingWith suffix: String) throws -> AgentStatus {
        try #require(agents.first { $0.id.hasSuffix("/" + suffix) }, "\(suffix) listed")
    }

    // MARK: - Parsers

    @Test func claudeKeepsTheLatestCwd() {
        var deduper = Deduper()
        let (parser, _) = ParserBehaviorTests.run(.claude, [
            Self.claudeUser("2026-10-20T10:00:00Z", cwd: "/Users/dev/one"),
            Self.claudeUser("2026-10-20T10:00:01Z", cwd: "/Users/dev/two words"),
            Self.claudeUser("2026-10-20T10:00:02Z", cwd: nil),
            Self.claudeUser("2026-10-20T10:00:03Z", cwd: ""),
        ], deduper: &deduper)
        #expect(parser.state.cwdPath == "/Users/dev/two words")
        #expect(parser.state.project == "two words")

        let (without, _) = ParserBehaviorTests.run(.claude, [Self.claudeUser("2026-10-20T10:00:00Z", cwd: nil)], deduper: &deduper)
        #expect(without.state.cwdPath == nil)
    }

    @Test func codexTakesTheFirstSessionMetaThenTurnContexts() {
        var deduper = Deduper()
        let meta = [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"child","cwd":"/w/child","thread_source":"subagent"}}"#,
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"parent","cwd":"/w/parent"}}"#,
        ]
        let (parser, _) = ParserBehaviorTests.run(.codex, meta, deduper: &deduper)
        #expect(parser.state.cwdPath == "/w/child")

        let (moved, _) = ParserBehaviorTests.run(.codex, meta + [
            #"{"timestamp":"2026-10-20T10:00:01Z","type":"turn_context","payload":{"model":"m","cwd":"/w/next"}}"#,
            #"{"timestamp":"2026-10-20T10:00:02Z","type":"turn_context","payload":{"model":"m"}}"#,
        ], deduper: &deduper)
        #expect(moved.state.cwdPath == "/w/next")
        #expect(moved.state.project == "next")

        let (without, _) = ParserBehaviorTests.run(.codex, [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":{"id":"t"}}"#,
        ], deduper: &deduper)
        #expect(without.state.cwdPath == nil)
    }

    @Test func dshUsesTheHeaderCwd() {
        var deduper = Deduper()
        let (parser, _) = DshParserTests.run([DshParserTests.header()], deduper: &deduper)
        #expect(parser.state.cwdPath == "/Users/dev/quasar")

        let (without, _) = DshParserTests.run([#"{"type":"session","version":4,"id":"s2","createdAt":1000000}"#], deduper: &deduper)
        #expect(without.state.cwdPath == nil)
    }

    @Test func opencodeUsesTheSessionDirectory() {
        let info = OpencodeSessionInfo(id: "s", parentId: nil, directory: "/Users/dev/projects/nebula", createdMs: 0, updatedMs: 0)
        #expect(OpencodeRules.state(of: info, rows: []).cwdPath == "/Users/dev/projects/nebula")
        for directory in [nil, ""] as [String?] {
            let bare = OpencodeSessionInfo(id: "s", parentId: nil, directory: directory, createdMs: 0, updatedMs: 0)
            #expect(OpencodeRules.state(of: bare, rows: []).cwdPath == nil)
        }
    }

    @Test func geminiUsesTheProjectRootFile() throws {
        let orbit = ParserFixtureTests.parser(for: "gemini/tmp/orbit/chats/session-2026-10-20T10-30-7f3a2b10.jsonl", fileID: 0)
        #expect(orbit.state.cwdPath == #"c:\users\dev\projects\orbit"#)
        let nested = "gemini/tmp/orbit/chats/7f3a2b10-5c1d-4e2f-9a3b-0c4d5e6f7a8b/0b8e6d2c-3f4a-4b5c-8d6e-7f8091a2b3c4.jsonl"
        #expect(ParserFixtureTests.parser(for: nested, fileID: 0).state.cwdPath == #"c:\users\dev\projects\orbit"#)

        let directory = try TempDirectory()
        try directory.write("home/tmp/spaced/.project_root", "  /Users/dev/My Project\n")
        try directory.write("home/projects.json", #"{"projects":{"/Users/dev/listed":"listed"}}"#)
        try directory.write("home/tmp/blank/.project_root", " \n")
        let spaced = TranscriptParser(family: .gemini, agentId: directory.file("home/tmp/spaced/chats/session-a.jsonl").path, fileID: 0)
        #expect(spaced.state.cwdPath == "/Users/dev/My Project")
        #expect(spaced.state.project == "My Project")
        // A name found only in the registry has no `.project_root` content.
        let listed = TranscriptParser(family: .gemini, agentId: directory.file("home/tmp/listed/chats/session-b.jsonl").path, fileID: 0)
        #expect(listed.state.project == "listed")
        #expect(listed.state.cwdPath == nil)
        let blank = TranscriptParser(family: .gemini, agentId: directory.file("home/tmp/blank/chats/session-c.jsonl").path, fileID: 0)
        #expect(blank.state.cwdPath == nil)
    }

    @Test func geminiDocumentReplayKeepsTheRoot() throws {
        let directory = try TempDirectory()
        try directory.write("tmp/doc/.project_root", "/Users/dev/doc")
        let path = directory.file("tmp/doc/chats/session-2026-10-20T10-00-aaaaaaaa.json").path
        var parser = TranscriptParser(family: .gemini, agentId: path, fileID: 0)
        var deduper = Deduper()
        for _ in 0..<2 {
            var document = GeminiTests.legacyDocument([(id: "g1", output: 10)])
            document.withUTF8 { parser.consume(rawLine: UnsafeRawBufferPointer($0), deduper: &deduper) { _ in } }
        }
        #expect(parser.state.cwdPath == "/Users/dev/doc")
    }

    @Test func ompUsesTheHeaderCwd() {
        #expect(OmpTests.run([OmpTests.header(cwd: "/Users/dev/projects/nova")]).state.cwdPath == "/Users/dev/projects/nova")
        #expect(OmpTests.run([OmpTests.header(cwd: "")]).state.cwdPath == nil)
        #expect(OmpTests.run([#"{"type":"session","id":"s2","timestamp":"2026-10-20T10:00:00.000Z"}"#]).state.cwdPath == nil)
        // Only the first header counts.
        let twice = OmpTests.run([OmpTests.header(cwd: "/a/first"), OmpTests.header(cwd: "/a/second")])
        #expect(twice.state.cwdPath == "/a/first")
    }

    @Test func antigravityDecodesFileURIs() {
        let cases: [(String, String?)] = [
            ("file:///Users/dev/My%20Project", "/Users/dev/My Project"),
            ("file:///Users/dev/projects/orbit/", "/Users/dev/projects/orbit"),
            ("FILE://localhost/Users/dev/x", "/Users/dev/x"),
            ("file:/Users/dev/y", "/Users/dev/y"),
            ("file:///", "/"),
            ("file:///a/%zz/%C3%A9", "/a/%zz/é"),
            ("file://server/share/x", nil),
            ("file:relative/x", nil),
            ("vscode-remote://ssh-remote%2Bbox/home/dev/x", nil),
            ("/Users/dev/plain", nil),
            ("", nil),
        ]
        for (uri, path) in cases {
            #expect(AntigravityBlobs.filePath(ofURI: uri) == path, "\(uri)")
        }
    }

    @Test func antigravityTakesTheURIOfTheProject() {
        func decoded(_ blob: [UInt8]) -> AntigravityTrajectory? {
            guard case .line(let trajectory) = blob.withUnsafeBytes({ AntigravityBlobs.trajectory($0) }) else { return nil }
            return trajectory
        }
        let workspace = PB.message(1, PB.string(1, "file:///Users/dev/workspace"))
        #expect(decoded(PB.string(7, "file:///Users/dev/My%20Project") + workspace)?.cwdPath == "/Users/dev/My Project")
        #expect(decoded(PB.string(7, "file:///") + workspace)?.cwdPath == "/Users/dev/workspace")
        let remote = decoded(PB.string(7, "vscode-remote://ssh-remote%2Bbox/home/dev/x") + workspace)
        #expect(remote?.project == "x")
        #expect(remote?.cwdPath == nil)
        #expect(decoded([])?.cwdPath == nil)
    }

    @Test func antigravityParserStoresThePath() throws {
        let path = Fixtures.root
            .appendingPathComponent("antigravity/antigravity-cli/conversations/3f6c2a10-8b4d-4e5f-9a1b-2c3d4e5f6a7b.db").path
        var parser = TranscriptParser(family: .antigravity, agentId: path, fileID: 0)
        var reader = TranscriptReader(path: path)
        let (batch, read) = reader.readDatabase()
        #expect(!read.failed)
        var deduper = Deduper()
        parser.consume(.antigravity(batch), deduper: &deduper) { _ in }
        #expect(parser.state.project == "star map")
        #expect(parser.state.cwdPath == "/Users/dev/projects/star map")
    }

    // MARK: - Engine and snapshot

    @Test func engineAgentCarriesTheStatePath() {
        var state = AgentState(source: .codex)
        #expect(EngineAgent(id: "a", state: state).cwdPath == nil)
        state.setProject(fromWorkingDirectory: "/w/p")
        #expect(EngineAgent(id: "a", state: state, parentId: "b").cwdPath == "/w/p")
    }

    @Test func snapshotAgentsCarryTheirPathThroughLiveUpdates() throws {
        let (directory, configuration) = try SessionTests.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration, clock: { 1_792_490_440_000 })
        let fixtureDay = Clock.milliseconds(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_792_490_400)))
        _ = session.seed(todayStartMs: fixtureDay)
        func agents(at nowMs: Int64) -> [AgentStatus] {
            let (output, _) = session.advance(nowMs: nowMs, todayStartMs: fixtureDay, emitsEvents: false)
            return SnapshotBuilder.running(output, context: SnapshotContext(session: session, todayStartMs: fixtureDay)).agents
        }
        let seeded = agents(at: 1_792_490_440_000)
        let rollout = "rollout-2026-10-20T10-00-00-modern.jsonl"
        #expect(try Self.agent(seeded, endingWith: rollout).cwdPath == "/Users/dev/projects/rocket")
        #expect(try Self.agent(seeded, endingWith: "s-cli.jsonl").cwdPath == "/Users/dev/projects/nova")
        #expect(try Self.agent(seeded, endingWith: "s-desk.jsonl").cwdPath == "/Users/dev/projects/orbit")
        #expect(try Self.agent(seeded, endingWith: "session-dsh-main/session.v4.jsonl.zstd").cwdPath == "/Users/dev/projects/quasar")

        let relative = "codex/sessions/2026/10/20/" + rollout
        try directory.append(relative, #"{"timestamp":"2026-10-20T10:00:30.000Z","type":"turn_context","payload":{"cwd":"/Users/dev/projects/rocket-2"}}"# + "\n")
        let canonical = try #require(realpath(directory.file(relative).path, nil))
        let canonicalPath = String(cString: canonical)
        free(canonical)
        #expect(session.handleChanges(atCanonicalPaths: [canonicalPath]))
        let moved = try Self.agent(agents(at: 1_792_490_441_000), endingWith: rollout)
        #expect(moved.cwdPath == "/Users/dev/projects/rocket-2")
        #expect(moved.project == "rocket-2")
    }

    @Test func opencodeSnapshotAgentsCarryTheDirectory() throws {
        let configuration = MonitorConfiguration(
            enabledSources: [.opencode],
            codexRoot: URL(fileURLWithPath: "/nonexistent/codex"),
            opencodeRoot: OpencodeTests.fixtureRoot
        )
        let session = TranscriptSession(configuration: configuration)
        _ = session.seed(todayStartMs: 0)
        let (output, _) = session.advance(nowMs: 1_792_490_750_000, todayStartMs: 1_792_454_400_000, emitsEvents: false)
        let agents = SnapshotBuilder.running(output, context: SnapshotContext(session: session, todayStartMs: 0)).agents
        #expect(agents.count == 2)
        #expect(agents.allSatisfy { $0.cwdPath == "/Users/dev/projects/nebula" })
    }

    @Test func publicInitDefaultsToNoPath() {
        let status = AgentStatus(id: "a", source: .codex, project: "p", model: nil, phase: .idle, isSubagent: false,
                                 live: .zero, recentSpeed: nil, lastActivity: Date(timeIntervalSince1970: 0))
        #expect(status.cwdPath == nil)
        var moved = status
        moved.cwdPath = "/w/p"
        #expect(moved != status)
    }
}
