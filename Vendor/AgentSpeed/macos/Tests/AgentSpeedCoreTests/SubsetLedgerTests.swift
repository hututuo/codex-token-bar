import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Subset ledger")
struct SubsetLedgerTests {
    static let day: Int64 = 1_800_000_000_000

    static func record(
        _ key: String,
        _ source: SourceKind,
        start: Int64?,
        end: Int64,
        output: Int,
        isFinal: Bool = true
    ) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: "\(source.rawValue)-agent", model: "m",
                       startMs: start, endMs: end, usage: TokenUsage(input: 7, output: output), isFinal: isFinal)
    }

    static let records = [
        record("c1", .codex, start: day + 10_000, end: day + 13_000, output: 900),
        record("c2", .codex, start: day + 40_200, end: day + 41_700, output: 450),
        record("k1", .claudeCode, start: day + 11_500, end: day + 14_000, output: 500),
        record("d1", .deepseek, start: day + 3_600_000, end: day + 3_602_000, output: 2000),
    ]

    static func ledger(_ records: [ResponseRecord]) -> DayLedger {
        var ledger = DayLedger(dayStartMs: day)
        for record in records { ledger.replace(nil, with: record) }
        return ledger
    }

    @Test func disjointSetsSumToTheAllSourcesPeak() {
        var ledger = Self.ledger(Self.records)
        let all = ledger.measuredPeak().output
        #expect(all > 0)
        #expect(abs(ledger.measuredPeakOutput(for: SourceSet([.codex, .claudeCode, .deepseek])) - all) < 1e-3)
        #expect(abs(ledger.measuredPeakOutput(for: .everything) - all) < 1e-3)

        for set in [SourceSet(.codex), SourceSet(.claudeCode), SourceSet(.deepseek), SourceSet([.codex, .claudeCode])] {
            var alone = Self.ledger(Self.records.filter { set.contains($0.source) })
            #expect(abs(ledger.measuredPeakOutput(for: set) - alone.measuredPeak().output) < 1e-3, "\(set.kinds)")
        }
        let pair = ledger.measuredPeakOutput(for: SourceSet([.codex, .claudeCode]))
        #expect(pair > ledger.measuredPeakOutput(for: SourceSet(.codex)))
        #expect(pair > ledger.measuredPeakOutput(for: SourceSet(.claudeCode)))
        #expect(ledger.measuredPeakOutput(for: SourceSet(.gemini)) == 0)
        #expect(ledger.measuredPeakOutput(for: []) == 0)
    }

    @Test func changesRecomputeOnlyTheAffectedSets() {
        let codex = SourceSet(.codex)
        let claude = SourceSet(.claudeCode)
        let both = codex.union(claude)
        var ledger = Self.ledger(Self.records)
        let claudePeak = ledger.measuredPeakOutput(for: claude)
        _ = ledger.measuredPeakOutput(for: codex)
        _ = ledger.measuredPeakOutput(for: both)
        #expect(ledger.subsetPeakScans == 3)
        _ = ledger.measuredPeakOutput(for: codex)
        _ = ledger.measuredPeakOutput(for: claude)
        _ = ledger.measuredPeakOutput(for: both)
        #expect(ledger.subsetPeakScans == 3, "answered from the cache")

        ledger.replace(Self.records[0], with: nil)
        ledger.replace(Self.records[1], with: nil)
        #expect(ledger.measuredPeakOutput(for: codex) < 1e-6, "only Float rounding residue is left")
        #expect(ledger.measuredPeakOutput(for: claude) == claudePeak)
        #expect(abs(ledger.measuredPeakOutput(for: both) - claudePeak) < 1e-9)
        #expect(ledger.subsetPeakScans == 5, "codex and the pair recomputed, claude still cached")

        let grown = Self.record("k1", .claudeCode, start: Self.day + 11_500, end: Self.day + 14_000, output: 5000)
        ledger.replace(Self.records[2], with: grown)
        #expect(abs(ledger.measuredPeakOutput(for: claude) - 5000.0 / 3) < 1e-3)
        #expect(ledger.measuredPeakOutput(for: codex) < 1e-6)
        #expect(ledger.subsetPeakScans == 6)
    }

    @Test func onlyTouchedBlocksAreRescanned() {
        var records = Self.records
        var ledger = Self.ledger(records)
        let all = SourceSet.everything
        _ = ledger.measuredPeakOutput(for: all)
        let initial = ledger.subsetScannedBlocks
        #expect(initial == 3600 / SourceSeconds.blockSeconds + 1, "from the first to the last second with data")

        let late = Self.record("c3", .codex, start: Self.day + 80_000_000, end: Self.day + 80_001_000, output: 5000)
        records.append(late)
        ledger.replace(nil, with: late)
        #expect(abs(ledger.measuredPeakOutput(for: all) - 5000.0 / 3) < 1e-3)
        #expect(ledger.subsetScannedBlocks == initial + 1)

        ledger.replace(late, with: nil)
        records.removeLast()
        ledger.replace(records[3], with: nil)
        records.remove(at: 3)
        var fresh = Self.ledger(records)
        #expect(abs(ledger.measuredPeakOutput(for: all) - fresh.measuredPeak().output) < 1e-3)
        #expect(abs(ledger.measuredPeakOutput(for: all) - 400) < 1e-3, "the codex + Claude Code overlap is left")
        #expect(ledger.subsetScannedBlocks == initial + 3)
    }

    @Test func unmeasuredUpdatesKeepTheCache() {
        let claude = SourceSet(.claudeCode)
        var ledger = Self.ledger(Self.records)
        let peak = ledger.measuredPeakOutput(for: claude)
        let streaming = Self.record("k2", .claudeCode, start: Self.day + 20_000, end: Self.day + 21_000, output: 50, isFinal: false)
        ledger.replace(nil, with: streaming)
        ledger.replace(streaming, with: Self.record("k2", .claudeCode, start: Self.day + 20_000, end: Self.day + 22_000, output: 90, isFinal: false))
        #expect(ledger.measuredPeakOutput(for: claude) == peak)
        #expect(ledger.subsetPeakScans == 1)
    }

    @Test func sourcesWithoutMeasuredDataGetNoBuckets() {
        var ledger = DayLedger(dayStartMs: Self.day)
        ledger.replace(nil, with: Self.record("u", .claudeCode, start: Self.day + 1000, end: Self.day + 2000, output: 10, isFinal: false))
        ledger.replace(nil, with: Self.record("n", .gemini, start: nil, end: Self.day + 2000, output: 10))
        ledger.replace(nil, with: Self.record("y", .deepseek, start: Self.day - 9000, end: Self.day - 1000, output: 10))
        ledger.replace(nil, with: Self.record("m", .opencode, start: Self.day - 3000, end: Self.day, output: 10))
        #expect(ledger.sourcesWithBuckets.isEmpty)
        #expect(ledger.totals.requests == 3)

        ledger.replace(nil, with: Self.records[0])
        #expect(ledger.sourcesWithBuckets == SourceSet(.codex))
        ledger.replace(Self.records[0], with: nil)
        #expect(ledger.measuredPeakOutput(for: SourceSet(.codex)) < 1e-6)
        #expect(ledger.measuredPeakOutput(for: .everything) < 1e-6)
    }

    @Test func sourceSetFollowsTheSourceOrder() {
        let set = SourceSet([.antigravity, .codex, .gemini, .codex])
        #expect(set.kinds == [.codex, .gemini, .antigravity])
        #expect(set.contains(.gemini))
        #expect(!set.contains(.claudeCode))
        #expect(set.rawValue == 1 | 1 << 5 | 1 << 7)
        #expect(SourceSet.everything.kinds == SourceKind.allCases)
        #expect(SourceSet().isEmpty)
        #expect(!SourceSet(.omp).isEmpty)
        #expect(SourceKind.allCases.enumerated().allSatisfy { $0.offset == $0.element.ordinal })
    }
}
