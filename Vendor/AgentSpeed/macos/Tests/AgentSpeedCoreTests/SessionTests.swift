import Foundation
import os
import Testing
@testable import AgentSpeedCore

@Suite("Transcript session")
struct SessionTests {
    /// Copies the shared fixtures into a scratch root with modification times that follow the fixture order.
    static func makeFixtureRoots() throws -> (TempDirectory, MonitorConfiguration) {
        let directory = try TempDirectory()
        let order = try #require(try Fixtures.json("parser-expected.json")["order"] as? [String])
        let start = Date().addingTimeInterval(-60)
        for (index, relative) in order.enumerated() {
            let bytes = try Data(contentsOf: Fixtures.root.appendingPathComponent(relative))
            try directory.write(relative, bytes: Array(bytes), modified: start.addingTimeInterval(TimeInterval(index)))
        }
        let configuration = MonitorConfiguration(
            codexRoot: directory.file("codex/sessions"),
            claudeRoot: directory.file("claude/projects"),
            dshRoot: directory.file("dsh/sessions"),
            opencodeRoot: directory.file("opencode"),
            geminiRoot: directory.file("gemini"),
            ompRoot: directory.file("missing-omp"),
            antigravityRoot: directory.file("missing-antigravity"),
            workbuddyRoot: directory.file("missing-workbuddy"),
            workbuddyAiRoot: directory.file("missing-workbuddy-ai"),
            zcodeRoot: directory.file("missing-zcode"),
            kimiRoot: directory.file("missing-kimi"),
            grokBuildRoot: directory.file("missing-grok-build")
        )
        return (directory, configuration)
    }

    static func startOfToday() -> Int64 { Clock.milliseconds(Calendar.current.startOfDay(for: Date())) }

    @Test func seedsFixturesWithoutLiveEvents() throws {
        let (directory, configuration) = try Self.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration)
        let fixtureDay = Clock.milliseconds(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_792_490_400)))
        let summary = session.seed(todayStartMs: fixtureDay)
        #expect(summary.filesRead == 9)
        #expect(summary.filesDiscovered == 9)
        #expect(Set(session.responses.map(\.key)) == [
            "resp-1", "resp-2", "resp-3", "resp-4", "codex-legacy:thread-legacy:20213", "codex-legacy:thread-legacy:41000",
            "resp-z1", "resp-z2",
            "msg_A", "msg_B", "msg_C", "msg_D", "msg_E", "dsm-1", "dsm-2", "dss-1",
        ])
        #expect(session.responses.first { $0.key == "msg_B" }?.agentId.hasSuffix("s-cli.jsonl") == true)
        #expect(session.responses.first { $0.key == "dsm-1" }?.agentId.hasSuffix("session-dsh-main/session.v4.jsonl.zstd") == true)
        #expect(session.responses.first { $0.key == "dss-1" }?.source == .deepseek)
        #expect(session.malformedLines == 2)
        #expect(session.responses.first { $0.key == "msg_E" }?.isFinal == false)
        let (output, events) = session.advance(nowMs: 1_792_491_000_000, todayStartMs: fixtureDay, emitsEvents: true)
        #expect(events.isEmpty)
        let context = SnapshotContext(session: session, todayStartMs: fixtureDay)
        #expect(context.warnings(for: output) == [.malformedLines(2), .unfinalizedUsage(1)])
        #expect(context.sources[.deepseek]?.available == true)
        #expect(context.sources[.deepseek]?.rootPath == directory.file("dsh/sessions").path)
        _ = directory
    }

    @Test func subagentsAreListedRightAfterTheirParents() throws {
        let (directory, configuration) = try Self.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration)
        let fixtureDay = Clock.milliseconds(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_792_490_400)))
        _ = session.seed(todayStartMs: fixtureDay)
        // The Codex parent's last line is just over 10 minutes old; its sub-agent's is not.
        let (output, _) = session.advance(nowMs: 1_792_490_410_700 + 600_001, todayStartMs: fixtureDay, emitsEvents: false)
        let agents = SnapshotBuilder.running(output, context: SnapshotContext(session: session, todayStartMs: fixtureDay)).agents
        let pairs = [
            ("rollout-2026-10-20T10-00-00-modern.jsonl", "rollout-2026-10-20T10-00-20-subagent.jsonl"),
            ("s-cli.jsonl", "agent-abc.jsonl"),
            ("session-dsh-main/session.v4.jsonl.zstd", "session-dsh-sub/session.v4.jsonl.zstd"),
        ]
        for (parentName, childName) in pairs {
            let child = try #require(agents.firstIndex { $0.id.hasSuffix("/" + childName) }, "\(childName) listed")
            #expect(child > 0)
            #expect(agents[child - 1].id.hasSuffix("/" + parentName), "\(childName) follows its parent")
            #expect(agents[child].parentId == agents[child - 1].id)
            #expect(agents[child - 1].parentId == nil)
        }
        #expect(agents.count == 9)
        #expect(agents.filter { $0.parentId != nil }.count == 3)
        _ = directory
    }

    @Test func disabledSourcesAreExcluded() throws {
        let (directory, base) = try Self.makeFixtureRoots()
        var configuration = base
        configuration.enabledSources = [.claudeDesktop]
        let session = TranscriptSession(configuration: configuration)
        _ = session.seed(todayStartMs: Self.startOfToday())
        #expect(session.responses.map(\.key) == ["msg_C"])
        _ = directory
    }

    @Test func liveAppendsProduceCompletionsAndTruncationDoesNotDoubleCount() throws {
        let (directory, configuration) = try Self.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration, clock: { 1_792_490_440_000 })
        _ = session.seed(todayStartMs: Self.startOfToday())
        let relative = "codex/sessions/2026/10/20/rollout-2026-10-20T10-00-00-modern.jsonl"
        try directory.append(relative, #"{"timestamp":"2026-10-20T10:00:20.000Z","type":"event_msg","payload":{"type":"user_message","message":"x"}}"# + "\n")
        try directory.append(relative, #"{"timestamp":"2026-10-20T10:00:24.000Z","type":"token_usage_record","payload":{"response_id":"resp-live","usage":{"input_tokens":100,"output_tokens":80}}}"# + "\n")

        let canonical = try #require(realpath(directory.file(relative).path, nil))
        let canonicalPath = String(cString: canonical)
        free(canonical)
        #expect(session.handleChanges(atCanonicalPaths: [canonicalPath]))
        let observation = session.consumeReadObservation()
        #expect(observation?.sourceMode == "log", "a watcher-triggered local read is still a log observation")
        #expect(observation?.sourceResolutionMs == nil, "FSEvents does not establish upstream log flush cadence")
        #expect((observation?.observedAtMs ?? 0) > 0)
        #expect((observation?.observedTickMs ?? 0) > 0)
        #expect(session.consumeReadObservation() == nil, "an observation is consumed once")
        let now = Clock.milliseconds(Date())
        let (_, events) = session.advance(nowMs: now, todayStartMs: Self.startOfToday(), emitsEvents: true)
        #expect(events.count == 1)
        if case .responseCompleted(let summary)? = events.first {
            #expect(summary.outputTokens == 80)
            #expect(summary.duration == 4)
            #expect(summary.project == "rocket")
        } else {
            Issue.record("expected a completion")
        }
        let requestsBefore = session.responses.count

        // Rewrite the file shorter: the parser restarts, already-counted keys are not counted again.
        let original = try String(contentsOf: Fixtures.root.appendingPathComponent(relative), encoding: .utf8)
        let firstLines = original.split(separator: "\n").prefix(8).joined(separator: "\n") + "\n"
        try Data(firstLines.utf8).write(to: directory.file(relative))
        #expect(session.handleChanges(atCanonicalPaths: [canonicalPath]))
        let (_, afterReset) = session.advance(nowMs: now + 10, todayStartMs: Self.startOfToday(), emitsEvents: true)
        #expect(afterReset.isEmpty)
        #expect(session.responses.count == requestsBefore)
    }

    @Test func newFilesAreDiscoveredAndReadFromTheStart() throws {
        let (directory, configuration) = try Self.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration)
        _ = session.seed(todayStartMs: Self.startOfToday())
        try directory.write("claude/projects/-w-new/s-new.jsonl", [
            #"{"type":"user","entrypoint":"cli","cwd":"/w/new","message":{"role":"user","content":"hi"},"timestamp":"2026-10-20T10:05:00.000Z"}"#,
            #"{"type":"assistant","entrypoint":"cli","cwd":"/w/new","message":{"id":"msg_new","model":"m","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":30}},"timestamp":"2026-10-20T10:05:03.000Z"}"#,
        ].joined(separator: "\n") + "\n")
        #expect(session.rediscover(todayStartMs: Self.startOfToday()))
        let record = session.responses.first { $0.key == "msg_new" }
        #expect(record?.startMs == Timestamp.parse("2026-10-20T10:05:00.000Z"))
        #expect(record?.source == .claudeCode)
    }

    @Test func deepseekFramesAppendedLiveProduceCompletions() throws {
        let (directory, configuration) = try Self.makeFixtureRoots()
        let session = TranscriptSession(configuration: configuration, clock: { 1_792_490_700_000 })
        _ = session.seed(todayStartMs: Self.startOfToday())
        let relative = "dsh/sessions/--Users-dev-projects-quasar--/session-dsh-sub/session.v4.jsonl.zstd"
        let message = #"{"type":"assistant/message","seq":26,"time":1792490657010,"data":{"message":{"id":"dss-live","#
            + #""content":[{"type":"text"}],"source":{"model":"deepseek-pro"}},"usage":{"inputTokens":10,"outputTokens":120}}}"#
        try directory.append(relative, bytes: ZstdFrames.raw(message + "\n"))
        let canonical = try #require(realpath(directory.file(relative).path, nil))
        let canonicalPath = String(cString: canonical)
        free(canonical)
        #expect(session.handleChanges(atCanonicalPaths: [canonicalPath, canonicalPath.replacingOccurrences(of: "session.v4.jsonl.zstd", with: "session.lock")]))
        let (_, events) = session.advance(nowMs: Clock.milliseconds(Date()), todayStartMs: Self.startOfToday(), emitsEvents: true)
        #expect(events.count == 1)
        if case .responseCompleted(let summary)? = events.first {
            #expect(summary.source == .deepseek)
            #expect(summary.outputTokens == 120)
            #expect(summary.duration == 2)
            #expect(summary.project == "quasar")
        } else {
            Issue.record("expected a completion")
        }

        let fresh = "dsh/sessions/--w-nebula--/session-new/session.v4.jsonl.zstd"
        try directory.write(fresh, bytes: ZstdFrames.raw([
            #"{"type":"session","version":4,"id":"session-new","createdAt":1792490700000,"cwd":"/w/nebula"}"#,
            #"{"type":"step/start","seq":1,"time":1792490701000,"data":{}}"#,
            #"{"type":"assistant/message","seq":2,"time":1792490703000,"data":{"message":{"id":"dsn-1"},"usage":{"outputTokens":7}}}"#,
        ].joined(separator: "\n") + "\n"))
        #expect(session.rediscover(todayStartMs: Self.startOfToday()))
        #expect(session.responses.first { $0.key == "dsn-1" }?.startMs == 1_792_490_701_000)
    }

    @Test func largeFrameStreamsStartAtTheirEndWithAWarning() throws {
        let directory = try TempDirectory()
        let relative = "--w-big--/session-big/session.v4.jsonl.zstd"
        func message(_ id: String, _ seq: Int) -> String {
            #"{"type":"assistant/message","seq":\#(seq),"time":1792490703000,"data":{"message":{"id":"\#(id)"},"usage":{"outputTokens":7}}}"#
        }
        let seeded = ZstdFrames.raw(message("before", 1) + "\n")
        try directory.write(relative, bytes: seeded)
        let limits = TranscriptSession.ReadingLimits(largeFileBytes: Int64(seeded.count - 1))
        let session = TranscriptSession(
            configuration: MonitorConfiguration(enabledSources: [.deepseek], dshRoot: directory.url),
            limits: limits
        )
        let summary = session.seed(todayStartMs: Self.startOfToday())
        #expect(summary.partialHistory)
        #expect(summary.filesRead == 0)
        #expect(session.responses.isEmpty)
        try directory.append(relative, bytes: ZstdFrames.raw(message("after", 2) + "\n"))
        #expect(session.pollRecentFiles(nowMs: Clock.milliseconds(Date())))
        #expect(session.responses.map(\.key) == ["after"])
    }

    @Test func oldFilesStartAtTheirEnd() throws {
        let directory = try TempDirectory()
        let relative = "2026/10/01/rollout-old.jsonl"
        try directory.write(relative, #"{"timestamp":"2026-10-01T10:00:00Z","type":"token_usage_record","payload":{"response_id":"old","usage":{"output_tokens":5}}}"# + "\n",
                            modified: Date().addingTimeInterval(-3 * 86_400))
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.url))
        let summary = session.seed(todayStartMs: Self.startOfToday())
        #expect(summary.filesRead == 0)
        #expect(session.responses.isEmpty)
        try directory.append(relative, #"{"timestamp":"2026-10-01T10:00:09Z","type":"token_usage_record","payload":{"response_id":"new","usage":{"output_tokens":5}}}"# + "\n")
        // Not hot; a watcher event still picks up the change immediately.
        #expect(!session.pollRecentFiles(nowMs: Clock.milliseconds(Date())))
        let canonical = try #require(realpath(directory.file(relative).path, nil))
        defer { free(canonical) }
        #expect(session.handleChanges(atCanonicalPaths: [String(cString: canonical)]))
        #expect(session.responses.map(\.key) == ["new"])
    }

    /// Codex keeps a session's rollout open while the session lives, often for days: FSEvents reports nothing until the
    /// file is closed, so rediscovery must notice such files waking up (issue #26).
    @Test func filesQuietForDaysAreRecheckedInTurnsWithoutWatcherEvents() throws {
        let directory = try TempDirectory()
        let turns = TranscriptSession.recheckTurns
        let old = Date().addingTimeInterval(-3 * 86_400)
        for index in 0..<turns {
            try directory.write("2026/10/01/rollout-\(index).jsonl",
                                #"{"timestamp":"2026-10-01T10:00:00Z","type":"token_usage_record","payload":{"response_id":"old-\#(index)","usage":{"output_tokens":5}}}"# + "\n",
                                modified: old.addingTimeInterval(TimeInterval(index)))
        }
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.url))
        #expect(session.seed(todayStartMs: Self.startOfToday()).filesRead == 0)
        for index in 0..<turns {
            try directory.append("2026/10/01/rollout-\(index).jsonl",
                                 #"{"timestamp":"2026-10-01T10:00:09Z","type":"token_usage_record","payload":{"response_id":"new-\#(index)","usage":{"output_tokens":5}}}"# + "\n")
        }
        #expect(!session.pollRecentFiles(nowMs: Clock.milliseconds(Date())))
        var readAfterRound: [Int] = []
        for _ in 0..<turns {
            #expect(session.rediscover(todayStartMs: Self.startOfToday()))
            readAfterRound.append(session.responses.count)
        }
        // One file in `turns` per round, so every quiet file is re-checked once a minute at little cost.
        #expect(readAfterRound == Array(1...turns))
        #expect(Set(session.responses.map(\.key)) == Set((0..<turns).map { "new-\($0)" }))
    }

    /// Issue #26: a session that went quiet in the evening and goes on the next morning, with its writer still holding
    /// the file open (no watcher event), counts toward the new day.
    @Test func aSessionThatResumesAfterMidnightIsReadWithoutWatcherEvents() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let evening = today.addingTimeInterval(-3 * 3600)
        let morning = today.addingTimeInterval(9 * 3600)
        let (todayStartMs, yesterdayStartMs) = (Clock.milliseconds(today), Clock.milliseconds(yesterday))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func turn(_ id: String, endingAt end: Date, output: Int) -> String {
            #"{"timestamp":"\#(formatter.string(from: end.addingTimeInterval(-4)))","type":"event_msg","payload":{"type":"user_message","message":"x"}}"#
                + "\n" + #"{"timestamp":"\#(formatter.string(from: end))","type":"token_usage_record","payload":{"response_id":"\#(id)","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"#
                + "\n"
        }
        let directory = try TempDirectory()
        let relative = "2026/10/27/rollout-evening.jsonl"
        try directory.write(relative, #"{"timestamp":"\#(formatter.string(from: evening.addingTimeInterval(-60)))","type":"session_meta","payload":{"id":"t-1","cwd":"/w/rocket"}}"#
                            + "\n" + turn("resp-evening", endingAt: evening, output: 40), modified: evening)
        let now = OSAllocatedUnfairLock(initialState: Clock.milliseconds(evening) + 60_000)
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.url),
                                        clock: { now.withLock { $0 } })
        _ = session.seed(todayStartMs: yesterdayStartMs)
        #expect(session.advance(nowMs: now.withLock { $0 }, todayStartMs: yesterdayStartMs, emitsEvents: false).output.today.output == 40)
        #expect(session.advance(nowMs: todayStartMs + 30_000, todayStartMs: todayStartMs, emitsEvents: true).output.today.output == 0)

        try directory.append(relative, turn("resp-morning", endingAt: morning, output: 80))
        try FileManager.default.setAttributes([.modificationDate: morning], ofItemAtPath: directory.file(relative).path)
        let nowMs = now.withLock { value in
            value = Clock.milliseconds(morning) + 1000
            return value
        }
        #expect(!session.pollRecentFiles(nowMs: nowMs), "quiet for hours, so not hot")
        #expect(session.rediscover(todayStartMs: todayStartMs), "changed within 24 hours, so re-checked every round")
        let (output, events) = session.advance(nowMs: nowMs, todayStartMs: todayStartMs, emitsEvents: true)
        #expect(output.today.output == 80)
        #expect(output.todayBySource[.codex]?.output == 80)
        #expect(output.agents.map { ($0.agent.id as NSString).lastPathComponent } == ["rollout-evening.jsonl"])
        #expect(events.count == 1)
        let context = SnapshotContext(session: session, todayStartMs: todayStartMs)
        #expect(SnapshotBuilder.running(output, context: context).sources.first { $0.kind == .codex }?.producedToday == true)
    }

    @Test func largeFilesAreSeededFromTheirTailWithAWarning() throws {
        let directory = try TempDirectory()
        var lines: [String] = []
        for index in 0..<40 {
            let second = String(format: "%02d", index)
            lines.append(#"{"timestamp":"2026-10-20T10:00:\#(second).000Z","type":"token_usage_record","payload":{"response_id":"r\#(index)","usage":{"output_tokens":1}}}"#)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try directory.write("2026/10/20/rollout-big.jsonl", text)
        let lineBytes = lines[39].utf8.count + 1
        let limits = TranscriptSession.ReadingLimits(largeFileBytes: Int64(text.utf8.count - 1), tailWindowBytes: Int64(lineBytes * 5 + 3))
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.url), limits: limits)
        let summary = session.seed(todayStartMs: Self.startOfToday())
        #expect(summary.partialHistory)
        #expect(Set(session.responses.map(\.key)) == ["r35", "r36", "r37", "r38", "r39"])
        #expect(SnapshotContext(session: session, todayStartMs: Self.startOfToday()).warnings == [.partialHistory])
    }
}
