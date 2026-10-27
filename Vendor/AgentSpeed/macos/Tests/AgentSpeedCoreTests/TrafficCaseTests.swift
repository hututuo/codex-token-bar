import Foundation
import Testing
@testable import AgentSpeedCore

/// Runs every `spec/fixtures/traffic-cases.json` case through `TrafficEngine` the way `spec/tools/traffic.py` does and
/// compares the keys the case lists (numbers within 0.001).
@Suite("Traffic fixture cases")
struct TrafficCaseTests {
    static func cases() throws -> [[String: Any]] {
        try #require(try Fixtures.json("traffic-cases.json")["cases"] as? [[String: Any]])
    }

    @Test func everyCasePasses() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 6)
        var names: [String] = []
        for testCase in cases {
            let name = testCase.string("name") ?? "?"
            names.append(name)
            let result = TrafficCaseRunner(testCase).run()
            var failures: [String] = []
            TrafficCaseRunner.diff("", want: testCase["expected"], got: result, into: &failures)
            #expect(failures.isEmpty, "\(name): \(failures.joined(separator: "; "))")
        }
        #expect(names.contains("classify-macos") && names.contains("classify-windows"))
    }
}

/// Fixture processes as an inspector: everything a case records for each identity.
final class FixtureInspector: ProcessInspector {
    var processes: [ProcessIdentity: [String: Any]] = [:]
    private(set) var argumentReads: [ProcessIdentity] = []

    func update(_ rows: [[String: Any]]) {
        for row in rows { processes[FixtureInspector.identity(row)] = row }
    }

    static func identity(_ row: [String: Any]) -> ProcessIdentity {
        ProcessIdentity(pid: Int32(row.int("pid")), startUs: (row.int64("start") ?? 0) * 1000)
    }

    static func entry(_ row: [String: Any]) -> ProcessEntry {
        ProcessEntry(pid: Int32(row.int("pid")), ppid: Int32(row.int("ppid")), startUs: (row.int64("start") ?? 0) * 1000)
    }

    func executablePath(of entry: ProcessEntry) -> String? { processes[entry.identity]?.string("exe") }

    func arguments(of entry: ProcessEntry) -> [String]? {
        argumentReads.append(entry.identity)
        return processes[entry.identity]?["args"] as? [String]
    }

    func workingDirectory(of entry: ProcessEntry) -> String? { processes[entry.identity]?.string("cwd") }

    func bundleIdentifier(of entry: ProcessEntry, executable: String) -> String? {
        processes[entry.identity]?.string("bundle")
    }

    func openFiles(of entry: ProcessEntry, nowMs: Int64) -> [String] {
        processes[entry.identity]?["openFiles"] as? [String] ?? []
    }
}

/// The JSON shape of `traffic.py run_case`.
struct TrafficCaseRunner {
    let testCase: [String: Any]
    let platform: TrafficPlatform
    let timeZone: TimeZone

    init(_ testCase: [String: Any]) {
        self.testCase = testCase
        platform = TrafficPlatform(
            kind: TrafficPlatform.Kind(rawValue: testCase.string("platform") ?? "macos") ?? .macos,
            home: testCase.string("home") ?? "/Users/dev",
            environment: testCase["env"] as? [String: String] ?? [:])
        timeZone = TimeZone(secondsFromGMT: Int((testCase.int64("tzOffsetMs") ?? 0) / 1000)) ?? .gmt
    }

    var agents: [TrafficAgent] {
        (testCase["agents"] as? [[String: Any]] ?? []).map { agent in
            let intervals = (agent["active"] as? [[NSNumber]] ?? []).map { $0[0].int64Value...$0[1].int64Value }
            return TrafficAgent(
                id: agent.string("id") ?? "", source: SourceKind(rawValue: agent.string("source") ?? "") ?? .codex,
                parentId: agent.string("parent"), cwdPath: agent.string("cwdPath"), transcript: agent.string("transcript"),
                activity: .intervals(intervals))
        }
    }

    func run() -> [String: Any] {
        let engine = TrafficEngine(platform: platform, timeZone: timeZone)
        engine.setAgents(agents)
        let inspector = FixtureInspector()
        let rateTimes = Set((testCase["rateTimes"] as? [NSNumber] ?? []).map(\.int64Value))
        var streams: [String: Int] = [:]
        var rates: [String: Any] = [:]
        var lastT: Int64 = 0
        for sample in testCase["samples"] as? [[String: Any]] ?? [] {
            let t = sample.int64("t") ?? 0
            lastT = t
            var processes: [ProcessEntry]?
            if let rows = sample["processes"] as? [[String: Any]] {
                inspector.update(rows)
                processes = rows.map(FixtureInspector.entry)
            }
            var interfaces: [String: TrafficCounter]?
            if let rows = sample["interfaces"] as? [String: [NSNumber]] {
                interfaces = rows.mapValues { TrafficCounter(rx: $0[0].int64Value, tx: $0[1].int64Value) }
            }
            var counters: CounterSample?
            if let raw = sample["counters"] as? [String: Any] {
                let id = raw.string("stream") ?? ""
                let stream = streams[id] ?? streams.count
                streams[id] = stream
                let rows = (raw["rows"] as? [[String: Any]] ?? []).map { row in
                    CounterSample.Row(identity: FixtureInspector.identity(row),
                                      counter: TrafficCounter(rx: row.int64("rx") ?? 0, tx: row.int64("tx") ?? 0))
                }
                counters = CounterSample(stream: stream, continues: raw["continues"] as? Bool ?? false, rows: rows)
            }
            engine.tick(TrafficSample(t: t, wallMs: t, processes: processes, interfaces: interfaces, counters: counters),
                        inspector: inspector)
            if rateTimes.contains(t) { rates[String(t)] = Self.rates(engine) }
        }
        var classes: [String: Any] = [:]
        for (identity, record) in engine.table.records.sorted(by: { $0.key < $1.key }) {
            classes[String(identity.pid)] = record.processClass.map { "\($0.source.rawValue)/\($0.role.rawValue)" } ?? NSNull()
        }
        var ledger = engine.ledger
        let today = ledger.totals(ledger.label(forMs: lastT)) ?? TrafficDayTotals()
        return [
            "classes": classes,
            "today": Self.today(today),
            "rates": rates,
            "history": engine.ledger.history.map(Self.row),
        ]
    }

    static func pair(_ rate: TrafficRate?) -> Any {
        rate.map { [$0.rx, $0.tx] } ?? NSNull()
    }

    static func rates(_ engine: TrafficEngine) -> [String: Any] {
        [
            "machine": pair(engine.machineRate),
            "sources": engine.sourceSeries.reduce(into: [String: Any]()) { result, entry in
                result[entry.key.rawValue] = ["withTools": pair(entry.value.withTools), "selfOnly": pair(entry.value.ownOnly)]
            },
            "agents": engine.agentSeries.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = ["withTools": pair(entry.value.withTools), "selfOnly": pair(entry.value.ownOnly)]
            },
        ]
    }

    static func split(_ split: TrafficSplit) -> [String: Any] {
        ["rxSelf": split.own.rx, "txSelf": split.own.tx, "rxTools": split.tools.rx, "txTools": split.tools.tx]
    }

    static func today(_ totals: TrafficDayTotals) -> [String: Any] {
        var sources: [String: Any] = [:]
        for (source, traffic) in totals.sources {
            var row = split(traffic.split)
            row["unassignedRx"] = traffic.unassigned.rx
            row["unassignedTx"] = traffic.unassigned.tx
            sources[source.rawValue] = row
        }
        return [
            "machine": ["rx": totals.machine.rx, "tx": totals.machine.tx, "sampledMs": totals.machineSampledMs],
            "sources": sources,
            "agents": totals.agents.mapValues(split),
        ]
    }

    static func row(_ day: TrafficDay) -> [String: Any] {
        ["day": day.day, "key": day.key, "rx": day.rx, "tx": day.tx, "rxTools": day.rxTools, "txTools": day.txTools,
         "sampledMs": day.sampledMs]
    }

    /// `traffic.py _diff`: only the wanted keys; lists must have the same length.
    static func diff(_ path: String, want: Any?, got: Any?, into out: inout [String]) {
        if let want = want as? [String: Any], let got = got as? [String: Any] {
            for (key, value) in want { diff("\(path).\(key)", want: value, got: got[key], into: &out) }
            return
        }
        if let want = want as? [Any], let got = got as? [Any], want.count == got.count {
            for (index, pair) in zip(want, got).enumerated() { diff("\(path)[\(index)]", want: pair.0, got: pair.1, into: &out) }
            return
        }
        let wantNull = want == nil || want is NSNull
        let gotNull = got == nil || got is NSNull
        if wantNull || gotNull {
            if wantNull != gotNull { out.append("\(path): want \(String(describing: want)), got \(String(describing: got))") }
            return
        }
        if let wanted = number(want), let value = number(got) {
            if abs(wanted - value) > 0.001 { out.append("\(path): want \(wanted), got \(value)") }
            return
        }
        if let wanted = want as? String, let value = got as? String, wanted == value { return }
        out.append("\(path): want \(String(describing: want)), got \(String(describing: got))")
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(value is String): number.doubleValue
        case let value as Int64: Double(value)
        case let value as Int: Double(value)
        case let value as Double: value
        default: nil
        }
    }
}
