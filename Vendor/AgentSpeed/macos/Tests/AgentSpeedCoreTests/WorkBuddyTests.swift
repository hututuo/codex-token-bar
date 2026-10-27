import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("WorkBuddy")
struct WorkBuddyTests {
    static var fixtures: [String: Any] {
        get throws { try #require(try Fixtures.json("parser-expected.json")["workbuddy"] as? [String: Any]) }
    }

    /// The fixture folder `workbuddy` plays the home folder of both editions.
    static var fixtureRoots: [(TranscriptFamily, String)] {
        let home = Fixtures.root.appendingPathComponent("workbuddy", isDirectory: true)
        return [(.workbuddy, ".workbuddy"), (.workbuddyAi, ".workbuddy-ai")].map { family, folder in
            (family, TranscriptLocations.workbuddyProjects(home.appendingPathComponent(folder, isDirectory: true)).path)
        }
    }

    // MARK: - Fixtures

    @Test func fixturesMatchTheReference() throws {
        let (expected, results) = try ParserFixtureTests.runFixtures()
        let files = try #require(expected["files"] as? [String: [String: Any]])
        let workbuddy = files.filter { $0.key.hasPrefix("workbuddy/") }
        #expect(workbuddy.count == 8)
        for (relative, spec) in workbuddy {
            let summary = OmpTests.summary(try #require(results[relative]))
            for (field, wanted) in spec where field != "parentFile" {
                let actual = summary[field] ?? NSNull()
                #expect((actual as AnyObject).isEqual(wanted), "\(relative) \(field): \(actual)")
            }
        }
    }

    @Test func tracesMatchPhaseAfterEveryCheckpoint() throws {
        let traces = try #require(try Self.fixtures["traces"] as? [[String: Any]])
        #expect(traces.count >= 45)
        for trace in traces {
            let file = try #require(trace.string("file"))
            let afterLine = trace.int("afterLine")
            var deduper = try OmpTests.deduper(before: file)
            var parser = ParserFixtureTests.parser(for: file, fileID: 999)
            try GeminiTests.feed(file, into: &parser, deduper: &deduper, lines: afterLine)
            #expect(parser.state.phase.rawValue == trace.string("phase"), "\(file) line \(afterLine) phase")
            #expect(parser.state.inFlightStartMs == trace.int64("inFlightStartMs"), "\(file) line \(afterLine) inFlightStartMs")
        }
    }

    @Test func discoveryFindsOnlySessionFiles() throws {
        let wanted = try #require(try Self.fixtures["discover"] as? [String])
        let prefix = Fixtures.root.path + "/"
        var found: [String] = []
        for (family, root) in Self.fixtureRoots {
            #expect(family.names == .workbuddySession)
            var index = DirectoryIndex(root: root, names: family.names)
            found += index.scan().map { String($0.dropFirst(prefix.count)) }
        }
        #expect(found.sorted() == wanted)
    }

    /// File watcher paths are filtered by the same layout rule.
    @Test func watchedPathsFollowTheLayout() {
        let names = TranscriptNames.workbuddySession
        func accepts(_ relative: String) -> Bool {
            names.matches((relative as NSString).lastPathComponent)
                && names.accepts(relativeComponents: relative.split(separator: "/"))
        }
        #expect(accepts("w-atlas/1b2c.jsonl"))
        #expect(accepts("w-atlas/1b2c/subagents/agent-9.jsonl"))
        #expect(!accepts("cloud/user-1/1.jsonl"))
        #expect(!accepts("cloud/1.jsonl"))
        #expect(!accepts(".tmp/1.jsonl"))
        #expect(!accepts("w-atlas/.1b2c.jsonl"))
        #expect(!accepts("w-atlas/.1b2c/subagents/agent-9.jsonl"))
        #expect(!accepts("stray.jsonl"))
        #expect(!accepts("w-atlas/1b2c/tool-results/call_1.jsonl"))
        #expect(!accepts("w-atlas/1b2c/subagents/workflows/wf_1/journal.jsonl"))
        #expect(!accepts("w-atlas/1b2c/subagents/nested/agent-deep.jsonl"))
        #expect(!accepts("w-atlas/1b2c.meta.json"))
    }

    @Test func rootsAreTheDataFoldersProjects() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = MonitorConfiguration()
        #expect(defaults.resolvedRoots(for: .workbuddy) == [home + "/.workbuddy/projects"])
        #expect(defaults.resolvedRoots(for: .workbuddyAi) == [home + "/.workbuddy-ai/projects"])
        let chosen = MonitorConfiguration(workbuddyRoot: URL(fileURLWithPath: "/data/wb/", isDirectory: true),
                                          workbuddyAiRoot: URL(fileURLWithPath: "/data/wb-ai/projects", isDirectory: true))
        #expect(chosen.resolvedRoots(for: .workbuddy) == ["/data/wb/projects"])
        #expect(chosen.resolvedRoots(for: .workbuddyAi) == ["/data/wb-ai/projects"])
        #expect(TranscriptLocations.workbuddyDataFolder(ofRoot: "/data/wb-ai/projects") == "/data/wb-ai")
        #expect(TranscriptFamily(.workbuddy) == .workbuddy && TranscriptFamily(.workbuddyAi) == .workbuddyAi)
    }

    // MARK: - Lines

    static let t0: Int64 = 1_792_576_800_000
    static let root = "/Users/dev/.workbuddy/projects"
    static let path = root + "/Users-dev-w-atlas/5f0c.jsonl"

    static func pd(_ members: String) -> String { #","providerData":{\#(members)}"# }

    static func line(_ type: String, _ ms: Int64, role: String? = nil, id: String? = nil, _ members: String = "",
                     cwd: String = "/Users/dev/w/atlas") -> String {
        let role = role.map { #","role":"\#($0)""# } ?? ""
        return #"{"id":"\#(id ?? "i\(ms)")","parentId":null,"timestamp":\#(ms),"type":"\#(type)"\#(role)\#(members),"cwd":"\#(cwd)"}"#
    }

    static func user(_ ms: Int64, skipRun: Bool = false) -> String {
        line("message", ms, role: "user", #","content":[{"type":"input_text","text":"(omitted)"}]"#
             + pd(skipRun ? #""skipRun":true"# : #""agent":"main""#))
    }

    static func usage(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0) -> String {
        #""usage":{"requests":1,"inputTokens":\#(input),"outputTokens":\#(output),"inputTokensDetails":[{"cached_tokens":\#(cached)}],"outputTokensDetails":[{"reasoning_tokens":\#(reasoning)}]}"#
    }

    static func say(_ ms: Int64, _ call: String, _ extra: String = "", status: String = "completed",
                    model: String = "glm-5.3") -> String {
        let members = #""messageId":"\#(call)","model":"\#(model)","requestModelId":"\#(model)""# + (extra.isEmpty ? "" : "," + extra)
        return line("message", ms, role: "assistant", #","status":"\#(status)","content":[{"type":"output_text","text":"(omitted)"}]"# + pd(members))
    }

    static func toolCall(_ ms: Int64, _ call: String, _ callId: String, _ extra: String = "") -> String {
        let members = #""messageId":"\#(call)","model":"glm-5.3""# + (extra.isEmpty ? "" : "," + extra)
        return line("function_call", ms, #","callId":"\#(callId)","name":"Read","arguments":"{}","status":"completed""# + pd(members))
    }

    static func result(_ ms: Int64, _ call: String, _ callId: String, skipRun: Bool = false, status: String = "completed") -> String {
        let skip = skipRun ? #","skipRun":true"# : ""
        return line("function_call_result", ms, #","name":"Read","callId":"\#(callId)","status":"\#(status)","output":{"type":"text","text":"(omitted)"}"#
                    + pd(#""messageId":"\#(call)","model":"glm-5.3""# + skip))
    }

    static func notice(_ ms: Int64, status: String = "completed", error: Bool = false) -> String {
        let error = error ? #","error":{"code":"aborted","message":"(omitted)"}"# : ""
        return line("message", ms, role: "assistant", #","status":"\#(status)","content":[]"# + pd(#""skipRun":true"# + error))
    }

    struct Run {
        var state: AgentState
        var responses: [ResponseRecord]
        var completions: [String]
    }

    static func run(_ lines: [String], path: String = path, source: SourceKind = .workbuddy, deduper: inout Deduper,
                    fileID: FileID = 1) -> Run {
        var parser = WorkBuddyParser(source: source, agentId: path, fileID: fileID, root: root)
        var order: [String] = []
        var latest: [String: ResponseRecord] = [:]
        var completions: [String] = []
        for text in lines {
            Data(text.utf8).withUnsafeBytes { bytes in
                parser.consume(WorkBuddyLineExtractor.extract(bytes), deduper: &deduper) { upsert in
                    if latest[upsert.record.key] == nil { order.append(upsert.record.key) }
                    latest[upsert.record.key] = upsert.record
                    if upsert.isCompletion { completions.append(upsert.record.key) }
                }
            }
        }
        return Run(state: parser.state, responses: order.compactMap { latest[$0] }, completions: completions)
    }

    static func run(_ lines: [String], path: String = path, source: SourceKind = .workbuddy) -> Run {
        var deduper = Deduper()
        return run(lines, path: path, source: source, deduper: &deduper)
    }

    static func tokens(_ providerData: String) -> TokenUsage? {
        let text = line("message", t0, role: "assistant", pd(#""messageId":"m1","# + providerData))
        return Data(text.utf8).withUnsafeBytes { bytes in
            guard case .line(let line) = WorkBuddyLineExtractor.extract(bytes) else { return nil }
            return line.call.tokens
        }
    }

    @Test func tokensTakeTheLargerOfBothRecords() {
        #expect(Self.tokens(#""usage":{"inputTokens":100,"outputTokens":10,"inputTokensDetails":[{"cached_tokens":40},{"cached_tokens":2},7],"outputTokensDetails":{"reasoning_tokens":3}}"#)
                == TokenUsage(input: 100, cachedInput: 42, output: 10, reasoning: 3))
        // DeepSeek reports hits and misses; a miss is uncached input, never a cache write.
        #expect(Self.tokens(#""rawUsage":{"prompt_tokens":1000,"completion_tokens":20,"prompt_cache_hit_tokens":900,"prompt_cache_miss_tokens":100}"#)
                == TokenUsage(input: 1000, cachedInput: 900, output: 20))
        #expect(Self.tokens(#""usage":{"inputTokens":500,"outputTokens":30,"outputTokensDetails":[{"reasoning_tokens":4}]},"rawUsage":{"prompt_tokens":520,"completion_tokens":28,"prompt_tokens_details":{"cached_tokens":300},"cache_creation_input_tokens":50,"completion_tokens_details":{"reasoning_tokens":9}}"#)
                == TokenUsage(input: 520, cachedInput: 300, cacheWriteInput: 50, output: 30, reasoning: 9))
        // The first value above 0 decides, truncated: 0.5 gives 0 although a later one is 7.
        #expect(Self.tokens(#""rawUsage":{"prompt_tokens":9,"cache_read_input_tokens":0.5,"prompt_tokens_details":{"cached_tokens":7}}"#)?.cachedInput == 0)
        #expect(Self.tokens(#""rawUsage":{"prompt_tokens":9,"cache_read_input_tokens":0,"prompt_tokens_details":{"cached_tokens":7}}"#)?.cachedInput == 7)
        #expect(Self.tokens(#""rawUsage":{"prompt_tokens":9,"prompt_cache_write_tokens":3.9}"#)?.cacheWriteInput == 3)
        // Input is at least the cache reads and writes.
        #expect(Self.tokens(#""usage":{"inputTokens":10,"outputTokens":1},"rawUsage":{"cache_read_input_tokens":100,"cache_creation_input_tokens":20}"#)?.input == 120)
        #expect(Self.tokens(#""usage":{"inputTokens":-5,"outputTokens":"7","inputTokensDetails":true},"rawUsage":{"completion_tokens":false,"prompt_tokens":12.9}"#)
                == TokenUsage(input: 12))
        #expect(Self.tokens(#""usage":"none","rawUsage":[1]"#) == nil)
        #expect(Self.tokens(#""usage":{}"#) == TokenUsage())
    }

    @Test func timestampsAreNumbersOrStrings() {
        func lastLine(_ timestamp: String) -> Int64? {
            Self.run([#"{"id":"a","timestamp":\#(timestamp),"type":"session-meta","cwd":"/w/x"}"#]).state.lastLineMs
        }
        #expect(lastLine("1792576800000") == 1_792_576_800_000)
        #expect(lastLine("1792576800000.9") == 1_792_576_800_000)
        #expect(lastLine(#""2026-10-21T10:00:00.250Z""#) == 1_792_576_800_250)
        #expect(lastLine(#""2026-10-21T12:00:00+02:00""#) == 1_792_576_800_000)
        for invalid in ["0", "-5", "true", "null", #""soon""#, "[1]", "{}"] {
            let run = Self.run([#"{"id":"a","timestamp":\#(invalid),"type":"message","role":"user","cwd":"/w/x"}"#])
            #expect(run.state.lastLineMs == nil && run.state.project == nil && run.state.phase == .idle, "\(invalid)")
        }
    }

    @Test func aTurnFromPromptToAnswer() {
        let run = Self.run([
            Self.user(Self.t0),
            #"{"id":"r1","timestamp":\#(Self.t0 + 3900),"type":"reasoning","content":[]\#(Self.pd(#""messageId":"m1""#)),"cwd":"/Users/dev/w/atlas"}"#,
            Self.say(Self.t0 + 3905, "m1", Self.usage(1200, 42, cached: 800, reasoning: 12)),
        ])
        #expect(run.responses.count == 1)
        let response = run.responses[0]
        #expect(response.key == "m1" && response.source == .workbuddy && response.agentId == Self.path)
        #expect(response.startMs == Self.t0 && response.endMs == Self.t0 + 3905 && response.isFinal)
        #expect(response.usage == TokenUsage(input: 1200, cachedInput: 800, output: 42, reasoning: 12))
        #expect(response.model == "glm-5.3" && response.provider == nil)
        #expect(run.state.phase == .idle && run.state.project == "atlas" && run.state.cwdPath == "/Users/dev/w/atlas")
        #expect(run.state.model == "glm-5.3" && !run.state.isSubagent)
        #expect(run.completions == ["m1"])
    }

    @Test func toolStepsStartAtTheResultThatCompletesThem() {
        var lines = [Self.user(Self.t0), Self.say(Self.t0 + 2500, "m1"),
                     Self.toolCall(Self.t0 + 2503, "m1", "c1"),
                     Self.toolCall(Self.t0 + 2506, "m1", "c2", Self.usage(1500, 26))]
        #expect(Self.run(lines).state.phase == .tools)
        lines.append(Self.result(Self.t0 + 9000, "m1", "c1"))
        #expect(Self.run(lines).state.phase == .tools, "one call is still open")
        lines.append(Self.result(Self.t0 + 9004, "m1", "c2"))
        var run = Self.run(lines)
        #expect(run.state.phase == .generating && run.state.inFlightStartMs == Self.t0 + 9004)
        // A failed tool continues the turn.
        lines += [Self.toolCall(Self.t0 + 12_300, "m2", "c3", Self.usage(1580, 9)),
                  Self.result(Self.t0 + 15_000, "m2", "c3", status: "incomplete")]
        run = Self.run(lines)
        #expect(run.state.phase == .generating && run.state.inFlightStartMs == Self.t0 + 15_000)
        lines.append(Self.say(Self.t0 + 19_200, "m3", Self.usage(1620, 31)))
        run = Self.run(lines)
        #expect(run.responses.map(\.startMs) == [Self.t0, Self.t0 + 9004, Self.t0 + 15_000])
        #expect(run.state.phase == .idle && run.state.inFlightStartMs == nil)
    }

    @Test func skipRunLinesEndOrLeaveTheTurn() {
        // A note the CLI adds starts nothing.
        #expect(Self.run([Self.user(Self.t0, skipRun: true)]).state.phase == .idle)
        // A rejected tool ends the turn: the next call has no start.
        var run = Self.run([Self.user(Self.t0), Self.toolCall(Self.t0 + 1500, "m1", "c1", Self.usage(100, 4)),
                            Self.result(Self.t0 + 20_000, "m1", "c1", skipRun: true),
                            Self.say(Self.t0 + 30_000, "m2", Self.usage(120, 5))])
        #expect(run.responses.map(\.startMs) == [Self.t0, nil])
        // Hook output while tools run changes nothing; an interruption or an error ends the turn.
        run = Self.run([Self.user(Self.t0), Self.toolCall(Self.t0 + 1500, "m1", "c1", Self.usage(100, 4)), Self.notice(Self.t0 + 1510)])
        #expect(run.state.phase == .tools)
        for ending in [Self.notice(Self.t0 + 2000, status: "incomplete"), Self.notice(Self.t0 + 2000, error: true)] {
            run = Self.run([Self.user(Self.t0), ending, Self.say(Self.t0 + 5000, "m1", Self.usage(100, 4))])
            #expect(run.state.phase == .idle && run.responses.first?.startMs == nil)
        }
        // A draft saved on interruption has no usage and changes nothing.
        run = Self.run([Self.user(Self.t0), Self.say(Self.t0 + 2000, "m1", #""isPartialAborted":true"#, status: "incomplete")])
        #expect(run.state.phase == .generating && run.responses.isEmpty)
    }

    @Test func compactionMakesRoomForTheRequestThatFollows() {
        let run = Self.run([Self.user(Self.t0), Self.say(Self.t0 + 8000, "m1", #""agent":"compact","# + Self.usage(60_000, 2000)),
                            Self.say(Self.t0 + 11_000, "m2", Self.usage(3000, 200))])
        #expect(run.responses.map(\.startMs) == [Self.t0, Self.t0 + 8000])
        let pending = Self.run([Self.user(Self.t0), Self.say(Self.t0 + 8000, "m1", #""agent":"compact","# + Self.usage(60_000, 2000))])
        #expect(pending.state.phase == .generating && pending.state.inFlightStartMs == Self.t0 + 8000)
    }

    @Test func modelUsageMergesIntoItsCallAndEndsTheRun() {
        func modelUsage(_ ms: Int64, _ call: String, _ usage: String) -> String {
            #"{"id":"mu\#(ms)","parentId":null,"timestamp":\#(ms),"type":"model-usage"\#(Self.pd(#""messageId":"\#(call)","model":"deepseek-v4-pro","# + usage)),"cwd":"/Users/dev/w/atlas"}"#
        }
        var deduper = Deduper()
        let run = Self.run([
            Self.user(Self.t0), Self.say(Self.t0 + 4000, "m1", Self.usage(16_200, 310, cached: 15_600)),
            Self.user(Self.t0 + 60_000),
            #"{"id":"r2","timestamp":\#(Self.t0 + 65_000),"type":"reasoning","content":[]\#(Self.pd(#""messageId":"m2""#)),"cwd":"/w"}"#,
            modelUsage(Self.t0 + 65_010, "m2", Self.usage(16_500, 80)),
            modelUsage(Self.t0 + 3998, "m1", Self.usage(16_200, 310, cached: 15_600, reasoning: 150)),
        ], deduper: &deduper)
        #expect(run.responses.map(\.key) == ["m1", "m2"])
        #expect(run.responses[0].endMs == Self.t0 + 4000, "the earlier time of a merged line keeps the later end")
        #expect(run.responses[0].usage.reasoning == 150 && run.responses[0].startMs == Self.t0)
        #expect(run.responses[0].model == "deepseek-v4-pro" && run.state.model == "deepseek-v4-pro")
        #expect(run.responses[1].startMs == Self.t0 + 60_000)
        #expect(run.completions == ["m1", "m2"], "a merge is an update")
        #expect(run.state.phase == .idle && run.state.cwdPath == "/Users/dev/w/atlas")
    }

    @Test func modelsDropTheUserProviderPrefix() {
        func call(_ members: String) -> WorkBuddyCall? {
            let text = Self.line("message", Self.t0, role: "assistant", Self.pd(members))
            return Data(text.utf8).withUnsafeBytes { bytes in
                guard case .line(let line) = WorkBuddyLineExtractor.extract(bytes) else { return nil }
                return line.call
            }
        }
        #expect(call(#""model":" glm-5.3 ","requestModelId":"auto""#)?.model == "glm-5.3")
        #expect(call(#""model":"  ","requestModelId":"auto""#)?.model == "auto")
        #expect(call(#""model":7,"requestModelId":" kimi-k3\n""#)?.model == "kimi-k3")
        #expect(call(#""requestModelName":"GLM-5.3""#)?.model == nil)
        let local = call(#""model":"  Custom-Local: claude-sonnet-5-5 ""#)
        #expect(local?.model == "claude-sonnet-5-5" && local?.provider == "custom")
        let custom = call(#""model":"custom:gpt-5.5""#)
        #expect(custom?.model == "gpt-5.5" && custom?.provider == "custom")
        let empty = call(#""model":"CUSTOM:  ""#)
        #expect(empty?.model == nil && empty?.provider == "custom")
        #expect(call(#""model":"customer:x""#)?.provider == nil)
        #expect(call(#""model":"custoḿ:x""#)?.provider == nil)
        #expect(call(#""messageId":"","model":"m""#)?.messageId == nil)
    }

    @Test func keysOwnedByAnotherFileAreIgnored() {
        var deduper = Deduper()
        let original = Self.run([Self.user(Self.t0), Self.toolCall(Self.t0 + 1000, "m1", "c1", Self.usage(100, 4))], deduper: &deduper)
        #expect(original.responses.count == 1)
        // A fork copies the lines: the copy's call is owned by the original and changes no phase.
        let fork = Self.run([Self.user(Self.t0), Self.toolCall(Self.t0 + 1000, "m1", "c1", Self.usage(100, 4))],
                            path: "/Users/dev/.workbuddy/projects/Users-dev-w-atlas/fork.jsonl", deduper: &deduper, fileID: 2)
        #expect(fork.responses.isEmpty && fork.state.phase == .generating && fork.state.lastLineMs == Self.t0 + 1000)
    }

    @Test func keysFallBackToTheLineId() {
        let run = Self.run([
            Self.user(Self.t0),
            Self.line("message", Self.t0 + 900, role: "assistant", id: "x1", Self.pd(Self.usage(10, 2))),
            Self.line("message", Self.t0 + 950, role: "assistant", id: "", Self.pd(Self.usage(10, 2))),
        ])
        #expect(run.responses.map(\.key) == ["workbuddy:x1"])
        #expect(run.state.phase == .idle)
        let noKey = Self.run([Self.user(Self.t0), Self.line("message", Self.t0 + 950, role: "assistant", id: "", Self.pd(""))])
        #expect(noKey.state.phase == .generating, "a line without any key changes no phase")
    }

    @Test func repeatedMembersKeepTheLastValue() {
        let run = Self.run([
            #"{"id":"u","timestamp":1,"timestamp":\#(Self.t0),"type":"message","role":"user","cwd":"/w/old","cwd":"/w/new"}"#,
            #"{"id":"a","timestamp":\#(Self.t0 + 10),"type":"message","role":"assistant","providerData":{"messageId":"m1","usage":{"inputTokens":5,"outputTokens":1}},"providerData":{"messageId":"m2","usage":{"inputTokens":7,"outputTokens":2}}}"#,
            #"{"id":"b","timestamp":\#(Self.t0 + 20),"type":"message","role":"user","providerData":{"skipRun":true},"providerData":"none"}"#,
        ])
        #expect(run.responses.map(\.key) == ["m2"] && run.responses[0].usage.input == 7)
        #expect(run.state.project == "new" && run.state.phase == .generating && run.state.inFlightStartMs == Self.t0 + 20)
    }

    @Test func malformedBlankAndIgnoredLines() {
        let run = Self.run(["{not json", "[1]", "\"text\"", "  \u{0B}\u{0C} ", "",
                            #"{"id":"s","timestamp":\#(Self.t0),"type":"summary","summary":"(omitted)"}"#,
                            #"{"id":"t","timestamp":\#(Self.t0 + 5),"type":"turn-metrics","role":"system","cwd":"   "}"#])
        #expect(run.state.malformedLines == 3)
        #expect(run.state.lastLineMs == Self.t0 + 5 && run.state.project == nil && run.responses.isEmpty)
    }

    @Test func subagentsAttachToTheirMainSessionOfTheSameEdition() {
        let projects = Self.root + "/Users-dev-w-atlas"
        let main = projects + "/5f0c.jsonl"
        let sub = projects + "/5f0c/subagents/agent-9.jsonl"
        #expect(WorkBuddyParser.isSubagent(path: sub, root: Self.root) && !WorkBuddyParser.isSubagent(path: main, root: Self.root))
        // The folder structure below the root decides, not a `subagents` folder above it or a project named so.
        #expect(!WorkBuddyParser.isSubagent(path: "/w/subagents/.workbuddy/projects/slug/5f0c.jsonl", root: "/w/subagents/.workbuddy/projects"))
        #expect(!WorkBuddyParser.isSubagent(path: Self.root + "/subagents/5f0c.jsonl", root: Self.root))
        #expect(WorkBuddyParser.isSubagent(path: "/w/subagents/.workbuddy/projects/slug/5f0c/subagents/a.jsonl",
                                           root: "/w/subagents/.workbuddy/projects/"))
        let edition = WorkBuddyParser(source: .workbuddyAi, agentId: sub, fileID: 0, root: Self.root).state
        #expect(edition.source == .workbuddyAi && edition.isSubagent)
        let members = [AgentParents.Member(id: main, family: .workbuddy), AgentParents.Member(id: sub, family: .workbuddy)]
        #expect(AgentParents.resolve(members) == [sub: main])
        let otherEdition = [AgentParents.Member(id: main, family: .workbuddyAi), AgentParents.Member(id: sub, family: .workbuddy)]
        #expect(AgentParents.resolve(otherEdition).isEmpty)
    }
}
