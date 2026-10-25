import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Traffic engine")
struct TrafficEngineTests {
    static let mac = TrafficPlatform(kind: .macos, home: "/Users/dev")
    static let claude = "/Users/dev/.local/share/claude/versions/2.1.303"

    /// A small table: launchd, a Claude Code process (pid 10) and its curl tool (pid 11), Safari (pid 20).
    static func processes(startUs: Int64 = 1_000_000, withTool: Bool = true) -> [[String: Any]] {
        var rows: [[String: Any]] = [
            ["pid": 1, "ppid": 0, "start": 0, "exe": "/sbin/launchd"],
            ["pid": 10, "ppid": 1, "start": startUs / 1000, "exe": claude, "args": ["claude"], "cwd": "/Users/dev/nova"],
            ["pid": 20, "ppid": 1, "start": startUs / 1000, "exe": "/Applications/Safari.app/Contents/MacOS/Safari"],
        ]
        if withTool { rows.append(["pid": 11, "ppid": 10, "start": startUs / 1000 + 1, "exe": "/usr/bin/curl"]) }
        return rows
    }

    final class Harness {
        let engine: TrafficEngine
        let inspector = FixtureInspector()
        var stream = 0
        var streamStartUs: Int64?

        init(timeZone: TimeZone = .gmt) {
            engine = TrafficEngine(platform: TrafficEngineTests.mac, timeZone: timeZone)
        }

        func identity(_ pid: Int32) -> ProcessIdentity {
            engine.table.identity(forPid: pid)!
        }

        func tick(_ t: Int64, processes: [[String: Any]]? = TrafficEngineTests.processes(), rows: [Int32: (Int64, Int64)]? = nil,
                  interfaces: [String: TrafficCounter]? = nil, continues: Bool = false, standby: Bool = false) {
            var entries: [ProcessEntry]?
            if let processes {
                inspector.update(processes)
                entries = processes.map(FixtureInspector.entry)
            }
            var counters: CounterSample?
            if rows != nil || standby {
                let mapped = (rows ?? [:]).compactMap { pid, value -> CounterSample.Row? in
                    guard let identity = engine.table.identity(forPid: pid) ?? entries?.first(where: { $0.pid == pid })?.identity
                    else { return nil }
                    return CounterSample.Row(identity: identity, counter: TrafficCounter(rx: value.0, tx: value.1))
                }
                counters = CounterSample(stream: stream, continues: continues, streamStartUs: streamStartUs, rows: mapped,
                                         isStandby: standby)
            }
            engine.tick(TrafficSample(t: t, wallMs: t, processes: entries, interfaces: interfaces, counters: counters),
                        inspector: inspector)
        }

        var claudeToday: SourceDayTraffic? { engine.today().sources[.claudeCode] }
    }

    @Test func diffReportsMismatches() {
        var out: [String] = []
        TrafficCaseRunner.diff("", want: ["a": 1, "b": [1, 2]] as [String: Any], got: ["a": 2, "b": [1]] as [String: Any], into: &out)
        #expect(out.count == 2)
        out = []
        TrafficCaseRunner.diff("", want: ["a": NSNull()] as [String: Any], got: ["a": 1.0] as [String: Any], into: &out)
        #expect(out.count == 1)
        out = []
        TrafficCaseRunner.diff("", want: ["a": 1.0004, "b": NSNull()] as [String: Any], got: ["a": 1.0] as [String: Any], into: &out)
        #expect(out.isEmpty)
    }

    @Test func deltasResetOnDecreaseAndAbove100Gbits() {
        #expect(CounterDelta.delta(from: 100, to: 250, intervalMs: 1000) == 150)
        #expect(CounterDelta.delta(from: 250, to: 100, intervalMs: 1000) == 0)
        #expect(CounterDelta.delta(from: 0, to: 12_500_000_000, intervalMs: 1000) == 12_500_000_000)
        #expect(CounterDelta.delta(from: 0, to: 12_500_000_001, intervalMs: 1000) == 0)
        #expect(CounterDelta.delta(from: 0, to: 25_000_000_000, intervalMs: 2000) == 25_000_000_000)
        #expect(CounterDelta.delta(from: 0, to: 1 << 40, intervalMs: nil) == 1 << 40)
    }

    @Test func argumentsAreReadOnlyForScriptHostsAndClaude() {
        let harness = Harness()
        harness.tick(1000)
        let reads = Set(harness.inspector.argumentReads.map(\.pid))
        #expect(reads == [10])
        harness.tick(2000)
        #expect(harness.inspector.argumentReads.count == 1)
    }

    @Test func forgottenKeysCountInFullWhenTheyReappear() {
        let harness = Harness()
        harness.tick(1000, rows: [10: (100, 10)])
        harness.tick(2000, rows: [10: (150, 10)])
        #expect(harness.claudeToday?.split.own == TrafficBytes(rx: 50, tx: 0))
        harness.tick(3000, rows: [:])
        harness.tick(4000, rows: [:])
        harness.tick(5000, rows: [10: (160, 10)])
        #expect(harness.claudeToday?.split.own == TrafficBytes(rx: 60, tx: 0), "two absences keep the baseline")
        for t in [6000, 7000, 8000] as [Int64] { harness.tick(t, rows: [:]) }
        harness.tick(9000, rows: [10: (170, 10)])
        #expect(harness.claudeToday?.split.own == TrafficBytes(rx: 230, tx: 10), "three absences forget it: d = cur")
    }

    @Test func aFirstSampleOnlyBaselinesProcessesThatPredateTheStream() {
        let harness = Harness()
        harness.streamStartUs = 1_000_500
        harness.tick(3000, rows: [10: (5000, 500), 11: (700, 70)])
        let today = harness.claudeToday
        #expect(today?.split.own == .zero, "Claude started before sampling began: a baseline")
        #expect(today?.split.tools == TrafficBytes(rx: 700, tx: 70), "curl started after: all of it is new")
    }

    @Test func standbyCountsAsSampledWithoutAgingBaselines() {
        let harness = Harness()
        harness.tick(1000, rows: [10: (100, 0)])
        harness.tick(2000, rows: [10: (200, 0)])
        for t in stride(from: Int64(3000), through: 8000, by: 1000) { harness.tick(t, standby: true) }
        #expect(harness.engine.today().processSampledMs == 7000)
        #expect(harness.engine.sourceSeries[.claudeCode]?.withTools == .zero)
        harness.tick(9000, rows: [10: (260, 0)], continues: true)
        #expect(harness.claudeToday?.split.own == TrafficBytes(rx: 160, tx: 0), "the baseline survived six standby ticks")
    }

    @Test func bucketsSpreadLongSamplesAndSkipGaps() {
        var buckets = TrafficBuckets()
        buckets.add(wallMs: 100_000, intervalMs: 1000, bytes: TrafficBytes(rx: 1000, tx: 0))
        buckets.add(wallMs: 105_000, intervalMs: 5000, bytes: TrafficBytes(rx: 5000, tx: 500))
        let points = buckets.points(nowMs: 105_400)
        #expect(points.count == 300)
        #expect(points.last?.time == Date(timeIntervalSince1970: 105))
        let tail = points.suffix(6).map(\.rate)
        #expect(tail == [TrafficRate(rx: 1000, tx: 0)] + Array(repeating: TrafficRate(rx: 1000, tx: 100), count: 5))
        let later = buckets.points(nowMs: 500_000)
        #expect(later.allSatisfy { $0.rate == .zero })
    }

    @Test func exitedProcessesMatchCounterRowsForTenSeconds() {
        let harness = Harness()
        harness.tick(1000, rows: [11: (0, 0)])
        harness.tick(2000, rows: [11: (100, 0)])
        let gone = TrafficEngineTests.processes(withTool: false)
        harness.tick(3000, processes: gone, rows: [11: (300, 0)])
        #expect(harness.claudeToday?.split.tools == TrafficBytes(rx: 300, tx: 0))
        harness.tick(13_500, processes: gone, rows: [:])
        #expect(harness.engine.table.identity(forPid: 11) == nil)
    }

    @Test func aProcessMissingFromOneListingStaysAndOthersArePruned() {
        let harness = Harness()
        harness.tick(1000)
        let withoutClaude = TrafficEngineTests.processes().filter { ($0["pid"] as? Int) != 10 }
        harness.tick(2000, processes: withoutClaude)
        let withoutTool = TrafficEngineTests.processes(withTool: false)
        harness.tick(3000, processes: withoutTool)
        #expect(harness.engine.table.record(harness.identity(10))?.alive == true, "back after one failed read")
        harness.tick(14_000, processes: withoutTool)
        #expect(harness.engine.table.identity(forPid: 11) == nil, "the tool that exited is pruned")
        #expect(harness.engine.table.identity(forPid: 10) != nil)
        #expect(harness.engine.table.hasAgentProcess)
    }

    @Test func deltasAfterMidnightStartTheNewDay() throws {
        let harness = Harness()
        let midnight: Int64 = 1_792_540_800_000
        harness.tick(midnight - 1000, interfaces: ["en0": TrafficCounter(rx: 0, tx: 0)])
        harness.tick(midnight - 1, interfaces: ["en0": TrafficCounter(rx: 100, tx: 10)])
        harness.tick(midnight + 999, interfaces: ["en0": TrafficCounter(rx: 300, tx: 30)])
        let days = harness.engine.ledger.days
        #expect(days.count == 2)
        let today = harness.engine.today()
        #expect(today.machine == TrafficBytes(rx: 200, tx: 20))
        #expect(today.machineSampledMs == 1000)
    }

    @Test func liveActivityPicksTheOnlyWorkingTree() {
        let harness = Harness()
        harness.engine.setAgents([
            TrafficAgent(id: "/t/a.jsonl", source: .claudeCode, cwdPath: "/Users/dev/nova", transcript: "/t/a.jsonl",
                         activity: .live(working: false, lastLineMs: 500)),
            TrafficAgent(id: "/t/b.jsonl", source: .claudeCode, cwdPath: "/Users/dev/orbit", transcript: "/t/b.jsonl",
                         activity: .live(working: true, lastLineMs: nil)),
            TrafficAgent(id: "/t/b-sub.jsonl", source: .claudeCode, parentId: "/t/b.jsonl", transcript: "/t/b-sub.jsonl",
                         activity: .live(working: false, lastLineMs: nil)),
        ])
        harness.tick(10_000, rows: [10: (0, 0)])
        harness.tick(11_000, rows: [10: (1000, 100)])
        #expect(harness.engine.today().agents["/t/b.jsonl"]?.own == TrafficBytes(rx: 1000, tx: 100))
        #expect(harness.engine.today().agents["/t/b-sub.jsonl"] == nil)
        #expect(harness.claudeToday?.unassigned == .zero)
    }

    @Test func workingDirectorySeparatesTwoActiveTrees() {
        let harness = Harness()
        harness.engine.setAgents([
            TrafficAgent(id: "a", source: .claudeCode, cwdPath: "/Users/dev/nova", activity: .live(working: true, lastLineMs: nil)),
            TrafficAgent(id: "b", source: .claudeCode, cwdPath: "/Users/dev/orbit", activity: .live(working: true, lastLineMs: nil)),
        ])
        harness.tick(10_000, rows: [10: (0, 0)])
        harness.tick(11_000, rows: [10: (1000, 100)])
        #expect(harness.engine.today().agents["a"]?.own == TrafficBytes(rx: 1000, tx: 100))
    }
}
