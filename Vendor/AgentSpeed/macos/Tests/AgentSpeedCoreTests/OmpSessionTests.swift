import Foundation
import Testing
@testable import AgentSpeedCore

/// omp inside the live session: automatic roots with profiles, sub-agent parents, and files that start being read
/// past their beginning (METRICS 4.7, 5, 6.7).
@Suite("omp session")
struct OmpSessionTests {
    static let base: Int64 = 1_792_493_400_000

    static func iso(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func header(_ ms: Int64, cwd: String) -> String {
        #"{"type":"session","version":3,"id":"s-\#(ms)","timestamp":"\#(iso(ms))","cwd":"\#(cwd)"}"# + "\n"
    }

    static func user(_ id: String, _ ms: Int64) -> String {
        #"{"type":"message","id":"\#(id)","timestamp":"\#(iso(ms))","message":{"role":"user","content":"(omitted)","timestamp":\#(ms)}}"# + "\n"
    }

    static func assistant(_ id: String, start: Int64, duration: Double, output: Int, stop: String = "stop") -> String {
        let end = start + Int64(duration)
        return #"{"type":"message","id":"\#(id)","timestamp":"\#(iso(end + 3))","message":{"role":"assistant","content":[{"type":"text","text":"(omitted)"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":3,"output":\#(output),"cacheRead":100,"cacheWrite":0},"stopReason":"\#(stop)","timestamp":\#(start),"duration":\#(duration)}}"#
            + "\n"
    }

    struct Home {
        let directory: TempDirectory
        var configuration: MonitorConfiguration

        init() throws {
            directory = try TempDirectory()
            for folder in [".omp/agent/sessions", ".omp/profiles/work/agent/sessions"] {
                try FileManager.default.createDirectory(at: directory.file(folder), withIntermediateDirectories: true)
            }
            configuration = MonitorConfiguration(enabledSources: [.omp])
            configuration.automaticRoots = [.omp: TranscriptLocations.ompRoots(environment: [:], home: directory.url)]
        }

        func path(_ relative: String) -> String { directory.file(relative).path }
    }

    @Test func automaticRootsIncludeProfilesAndSubagentsLinkToTheirStarter() throws {
        let home = try Home()
        #expect(home.configuration.resolvedRoots(for: .omp).map { ($0 as NSString).lastPathComponent } == ["sessions", "sessions"])
        let main = ".omp/agent/sessions/-w-pulsar/2026-10-20T10-50-00-000Z_main.jsonl"
        let task = ".omp/agent/sessions/-w-pulsar/2026-10-20T10-50-00-000Z_main/ScanCallSites.jsonl"
        let nested = ".omp/agent/sessions/-w-pulsar/2026-10-20T10-50-00-000Z_main/ScanCallSites/Verify.jsonl"
        let profile = ".omp/profiles/work/agent/sessions/-w-orbit/2026-10-20T10-55-00-000Z_work.jsonl"
        try home.directory.write(main, Self.header(Self.base, cwd: "/w/pulsar") + Self.user("u1", Self.base + 1000)
            + Self.assistant("a1", start: Self.base + 1005, duration: 2000.7, output: 120))
        try home.directory.write(task, Self.header(Self.base + 4000, cwd: "/w/pulsar") + Self.user("u1", Self.base + 4100)
            + Self.assistant("a1", start: Self.base + 4105, duration: 1500, output: 40))
        try home.directory.write(nested, Self.header(Self.base + 6000, cwd: "/w/pulsar")
            + Self.assistant("a1", start: Self.base + 6100, duration: 900, output: 20))
        try home.directory.write(profile, Self.header(Self.base + 8000, cwd: "/w/orbit")
            + Self.assistant("p1", start: Self.base + 8100, duration: 700, output: 30))
        try home.directory.write(".omp/agent/sessions/-w-pulsar/.omp-gc-compress-1/copy.jsonl",
                                 Self.header(Self.base, cwd: "/w/pulsar") + Self.assistant("a1", start: Self.base + 1005, duration: 2000, output: 120))
        try home.directory.write(".omp/agent/sessions/top-level.jsonl", Self.header(Self.base, cwd: "/w/stray"))

        let session = TranscriptSession(configuration: home.configuration, clock: { Self.base + 10_000 })
        let summary = session.seed(todayStartMs: Self.base)
        #expect(summary.filesDiscovered == 4, "dot folders and files directly in a root are not sessions")
        #expect(session.responses.count == 4)
        #expect(session.responses.first { $0.agentId == home.path(main) }?.endMs == Self.base + 1005 + 2000)
        let (output, _) = session.advance(nowMs: Self.base + 10_000, todayStartMs: Self.base, emitsEvents: false)
        let agents = Dictionary(uniqueKeysWithValues: output.agents.map { ($0.agent.id, $0) })
        #expect(agents[home.path(main)]?.parentId == nil && agents[home.path(main)]?.agent.isSubagent == false)
        #expect(agents[home.path(task)]?.parentId == home.path(main) && agents[home.path(task)]?.agent.isSubagent == true)
        #expect(agents[home.path(nested)]?.parentId == home.path(task))
        #expect(agents[home.path(profile)]?.agent.project == "orbit" && agents[home.path(profile)]?.parentId == nil)
        #expect(session.sessionCounts(todayStartMs: Self.base)[.omp] == 4)
    }

    @Test func anOlderFileThatGrowsReadsItsHeaderFirst() throws {
        let home = try Home()
        let relative = ".omp/agent/sessions/-w-nova/2026-10-19T09-00-00-000Z_old.jsonl"
        let title = #"{"type":"title","v":1,"title":"(omitted)","updatedAt":"2026-10-19T09:00:00.000Z"}"# + "\n"
        let yesterday = Self.base - 86_400_000
        try home.directory.write(relative, title + Self.header(yesterday, cwd: "/w/nova") + Self.user("u1", yesterday + 1000)
            + Self.assistant("a1", start: yesterday + 1005, duration: 1000, output: 10),
            modified: Date(timeIntervalSince1970: TimeInterval(yesterday) / 1000 + 5))
        let session = TranscriptSession(configuration: home.configuration, clock: { Self.base + 60_000 })
        let summary = session.seed(todayStartMs: Self.base)
        #expect(summary.filesRead == 0 && session.responses.isEmpty)

        // Resumed today: only the appended lines are read, after the header that names the project.
        try home.directory.append(relative, Self.user("u2", Self.base + 50_000)
            + Self.assistant("a2", start: Self.base + 50_005, duration: 4000.9, output: 80))
        let resolved = try #require(realpath(home.path(relative), nil))
        let canonical = String(cString: resolved)
        free(resolved)
        #expect(session.handleChanges(atCanonicalPaths: [canonical]))
        #expect(session.responses.map(\.key) == ["omp:a2:\(Self.base + 50_005)"])
        #expect(session.responses.first?.endMs == Self.base + 50_005 + 4000)
        let (output, events) = session.advance(nowMs: Self.base + 60_000, todayStartMs: Self.base, emitsEvents: true)
        #expect(output.agents.first?.agent.project == "nova")
        #expect(output.agents.first?.phase == .idle)
        #expect(events.count == 1)
    }

    @Test func historyReadsEveryRootIncludingProfiles() throws {
        let home = try Home()
        try home.directory.write(".omp/agent/sessions/-w-a/2026-10-20T10-00-00-000Z_a.jsonl",
                                 Self.header(Self.base, cwd: "/w/a") + Self.assistant("x", start: Self.base + 10, duration: 1000, output: 5))
        try home.directory.write(".omp/profiles/work/agent/sessions/-w-b/2026-10-20T10-00-00-000Z_b.jsonl",
                                 Self.header(Self.base, cwd: "/w/b") + Self.assistant("y", start: Self.base + 10, duration: 1000, output: 7))
        let report = try HistoryScan.run(configuration: home.configuration, timeZone: HistoryTests.utc)
        #expect(report.filesAnalyzed == 2)
        #expect(report.days.map(\.totals.output) == [12])
        #expect(report.days.first?.agents == 2)
    }
}
