import Foundation
import Testing
@testable import AgentSpeedCore

/// Run with `AGENT_SPEED_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter SubsetPerformance`.
@Suite("Subset performance", .enabled(if: ProcessInfo.processInfo.environment["AGENT_SPEED_BENCH"] == "1"))
struct SubsetPerformanceTests {
    static let day: Int64 = 1_800_000_000_000
    static let start = day + 86_000_000
    static let ticks = 200
    static let sets: Set<SourceSet> = [
        SourceSet(.codex), SourceSet(.claudeCode), SourceSet(.deepseek), SourceSet(.gemini),
        SourceSet([.claudeCode, .claudeDesktop]), SourceSet([.opencode, .omp, .antigravity]),
        SourceSet([.codex, .claudeCode, .deepseek, .opencode]), .everything,
    ]

    static func record(_ key: String, _ source: SourceKind, end: Int64, durationMs: Int64, output: Int) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: source.rawValue, model: "m", startMs: end - durationMs, endMs: end,
                       usage: TokenUsage(input: 100, output: output))
    }

    /// A response every 20 s from every source over the whole day.
    static var backlog: [ResponseRecord] {
        SourceKind.allCases.flatMap { source in
            stride(from: Int64(10_000), to: 86_000_000, by: 20_000).map { offset in
                record("\(source.rawValue)-\(offset)", source, end: day + offset + Int64(source.ordinal) * 500,
                       durationMs: 8000, output: 400 + source.ordinal * 10)
            }
        }
    }

    /// One new response per source and tick, so every requested set is recomputed.
    static func tickRecords(_ tick: Int) -> [ResponseRecord] {
        let now = start + Int64(tick) * 500
        return SourceKind.allCases.map { record("\($0.rawValue)-tick-\(tick)", $0, end: now, durationMs: 2000, output: 300) }
    }

    @Test func eightSetsOverEightBusySources() {
        var ledger = DayLedger(dayStartMs: Self.day)
        for record in Self.backlog { ledger.replace(nil, with: record) }
        let clock = ContinuousClock()
        var checksum = 0.0
        let cold = clock.measure {
            for set in Self.sets { checksum += ledger.measuredPeakOutput(for: set) }
        }
        var peaks = Duration.zero
        for tick in 0..<Self.ticks {
            for record in Self.tickRecords(tick) { ledger.replace(nil, with: record) }
            peaks += clock.measure {
                for set in Self.sets { checksum += ledger.measuredPeakOutput(for: set) }
            }
        }
        #expect(checksum > 0)

        var plain = SpeedEngine()
        var asked = SpeedEngine()
        for record in Self.backlog {
            plain.upsert(record, project: "p", isCompletion: true, emitsEvents: false)
            asked.upsert(record, project: "p", isCompletion: true, emitsEvents: false)
        }
        _ = plain.advance(nowMs: Self.start - 500, todayStartMs: Self.day, emitsEvents: false)
        _ = asked.advance(nowMs: Self.start - 500, todayStartMs: Self.day, emitsEvents: false, subsets: Self.sets)
        var without = Duration.zero
        var with = Duration.zero
        for tick in 0..<Self.ticks {
            let now = Self.start + Int64(tick) * 500
            for record in Self.tickRecords(tick) {
                plain.upsert(record, project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
                asked.upsert(record, project: "p", isCompletion: true, emitsEvents: true, nowMs: now)
            }
            without += clock.measure { _ = plain.advance(nowMs: now, todayStartMs: Self.day, emitsEvents: true) }
            with += clock.measure { _ = asked.advance(nowMs: now, todayStartMs: Self.day, emitsEvents: true, subsets: Self.sets) }
        }
        func microseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
        }
        let ledgerCost = microseconds(peaks) / Double(Self.ticks)
        let added = (microseconds(with) - microseconds(without)) / Double(Self.ticks)
        print("subset peaks: \(String(format: "%.1f", microseconds(cold))) µs for the first computation of 8 sets over a full day, "
              + "\(String(format: "%.1f", ledgerCost)) µs per tick for 8 recomputed sets; advance "
              + "\(String(format: "%.1f", microseconds(without) / Double(Self.ticks))) µs without, +\(String(format: "%.1f", added)) µs with")
        #expect(ledgerCost < 1000)
    }
}
