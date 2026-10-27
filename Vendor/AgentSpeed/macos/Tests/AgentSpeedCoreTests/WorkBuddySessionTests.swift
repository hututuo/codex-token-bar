import Foundation
import Testing
@testable import AgentSpeedCore

/// Both WorkBuddy editions inside the live session and the daily history: detection by the data folder, main sessions
/// and sub-agents, live appends (METRICS 2, 4.9, 6.7, 8; DESIGN 5).
@Suite("WorkBuddy session")
struct WorkBuddySessionTests {
    static let base = WorkBuddyTests.t0

    struct Home {
        let directory: TempDirectory
        var configuration: MonitorConfiguration

        /// A home folder whose data folders are chosen in settings (the data folder for one, `projects` for the other).
        init(sources: Set<SourceKind> = [.workbuddy, .workbuddyAi]) throws {
            directory = try TempDirectory()
            configuration = MonitorConfiguration(
                enabledSources: sources,
                workbuddyRoot: directory.file(".workbuddy"),
                workbuddyAiRoot: directory.file(".workbuddy-ai/projects")
            )
        }

        func path(_ relative: String) -> String { directory.file(relative).path }
    }

    static func turn(_ ms: Int64, _ call: String, output: Int, cwd: String = "/Users/dev/w/atlas") -> String {
        let usage = WorkBuddyTests.usage(1000, output, cached: 600)
        return WorkBuddyTests.line("message", ms, role: "user", WorkBuddyTests.pd(#""agent":"main""#), cwd: cwd) + "\n"
            + WorkBuddyTests.line("message", ms + 2000, role: "assistant",
                                  WorkBuddyTests.pd(#""messageId":"\#(call)","model":"glm-5.3","# + usage), cwd: cwd) + "\n"
    }

    @Test func aDataFolderWithoutProjectsIsDetectedWithNoSessions() throws {
        let home = try Home()
        try FileManager.default.createDirectory(at: home.directory.file(".workbuddy/app"), withIntermediateDirectories: true)
        let session = TranscriptSession(configuration: home.configuration, clock: { Self.base })
        #expect(session.hasAvailableRoot)
        let china = session.root(for: .workbuddy)
        #expect(china.detected && !china.available && china.path == home.path(".workbuddy/projects"))
        #expect(!session.root(for: .workbuddyAi).detected)
        let context = SnapshotContext(session: session, todayStartMs: Self.base)
        #expect(context.sources[.workbuddy]?.available == true && context.sources[.workbuddy]?.sessionCount == 0)
        #expect(context.sources[.workbuddyAi]?.available == false)
        #expect(session.watchedPaths.isEmpty, "nothing to watch before projects exists")

        // The first conversation creates projects; rediscovery reads it from the start.
        try home.directory.write(".workbuddy/projects/Users-dev-w-atlas/5f0c.jsonl", Self.turn(Self.base + 1000, "m1", output: 40))
        #expect(session.rediscover(todayStartMs: Self.base))
        #expect(session.responses.map(\.key) == ["m1"])
        #expect(session.watchedPaths.count == 1)
    }

    @Test func mainSessionsSubagentsAndBothEditions() throws {
        let home = try Home()
        let main = ".workbuddy/projects/Users-dev-w-atlas/5f0c.jsonl"
        let sub = ".workbuddy/projects/Users-dev-w-atlas/5f0c/subagents/agent-9.jsonl"
        let intl = ".workbuddy-ai/projects/C-Users-dev-w-orbit/7a1e.jsonl"
        try home.directory.write(main, Self.turn(Self.base + 1000, "m1", output: 40))
        try home.directory.write(sub, Self.turn(Self.base + 5000, "s1", output: 20))
        try home.directory.write(intl, Self.turn(Self.base + 9000, "d1", output: 30, cwd: #"C:\\Users\\dev\\w\\orbit"#))
        try home.directory.write(".workbuddy/projects/cloud/user-1/1.jsonl", Self.turn(Self.base + 1000, "c1", output: 99))
        try home.directory.write(".workbuddy/projects/Users-dev-w-atlas/5f0c/tool-results/call_1.jsonl",
                                 Self.turn(Self.base + 1000, "t1", output: 99))

        let session = TranscriptSession(configuration: home.configuration, clock: { Self.base + 60_000 })
        let summary = session.seed(todayStartMs: Self.base)
        #expect(summary.filesDiscovered == 3)
        #expect(Set(session.responses.map(\.key)) == ["m1", "s1", "d1"])
        #expect(session.responses.first { $0.key == "d1" }?.source == .workbuddyAi)
        let counts = session.sessionCounts(todayStartMs: Self.base)
        #expect(counts[.workbuddy] == 1, "a sub-agent transcript is not a session")
        #expect(counts[.workbuddyAi] == 1)
        let (output, _) = session.advance(nowMs: Self.base + 60_000, todayStartMs: Self.base, emitsEvents: false)
        let agents = Dictionary(uniqueKeysWithValues: output.agents.map { ($0.agent.id, $0) })
        #expect(agents[home.path(sub)]?.parentId == home.path(main) && agents[home.path(sub)]?.agent.isSubagent == true)
        #expect(agents[home.path(intl)]?.agent.project == "orbit")
        #expect(agents[home.path(intl)]?.agent.cwdPath == #"C:\Users\dev\w\orbit"#)
    }

    @Test func appendedLinesAreLiveCompletions() throws {
        let home = try Home(sources: [.workbuddy])
        let relative = ".workbuddy/projects/Users-dev-w-atlas/5f0c.jsonl"
        try home.directory.write(relative, Self.turn(Self.base + 1000, "m1", output: 40))
        let session = TranscriptSession(configuration: home.configuration, clock: { Self.base + 30_000 })
        _ = session.seed(todayStartMs: Self.base)
        _ = session.advance(nowMs: Self.base + 20_000, todayStartMs: Self.base, emitsEvents: false)

        try home.directory.append(relative, WorkBuddyTests.user(Self.base + 20_000) + "\n")
        let canonical = try Self.canonical(home.path(relative))
        #expect(session.handleChanges(atCanonicalPaths: [canonical]))
        var (output, events) = session.advance(nowMs: Self.base + 21_000, todayStartMs: Self.base, emitsEvents: true)
        #expect(output.agents.first?.phase == .generating && events.isEmpty)

        try home.directory.append(relative, WorkBuddyTests.say(Self.base + 24_000, "m2", WorkBuddyTests.usage(1100, 80)) + "\n")
        #expect(session.handleChanges(atCanonicalPaths: [canonical]))
        (output, events) = session.advance(nowMs: Self.base + 25_000, todayStartMs: Self.base, emitsEvents: true)
        #expect(output.agents.first?.phase == .idle)
        guard case .responseCompleted(let response)? = events.first else {
            Issue.record("no completion")
            return
        }
        #expect(response.source == .workbuddy && response.outputTokens == 80 && response.duration == 4)
    }

    @Test func historyReadsBothEditions() throws {
        let home = try Home()
        try home.directory.write(".workbuddy/projects/Users-dev-w-atlas/5f0c.jsonl", Self.turn(Self.base + 1000, "m1", output: 40))
        try home.directory.write(".workbuddy/projects/Users-dev-w-atlas/5f0c/subagents/agent-9.jsonl",
                                 Self.turn(Self.base + 5000, "s1", output: 20))
        try home.directory.write(".workbuddy-ai/projects/C-Users-dev-w-orbit/7a1e.jsonl", Self.turn(Self.base + 9000, "d1", output: 30))
        let report = try HistoryScan.run(configuration: home.configuration, timeZone: HistoryTests.utc)
        #expect(report.filesAnalyzed == 3)
        let rows = Dictionary(uniqueKeysWithValues: report.days.map { ($0.source, $0) })
        #expect(rows[.workbuddy]?.totals.output == 60 && rows[.workbuddy]?.agents == 2)
        #expect(rows[.workbuddyAi]?.totals.output == 30 && rows[.workbuddyAi]?.totals.cachedInput == 600)
        #expect(rows[.workbuddy]?.measuredMs == 4000)
    }

    static func canonical(_ path: String) throws -> String {
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
