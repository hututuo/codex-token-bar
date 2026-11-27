import Foundation
import XCTest
@testable import AgentSpeedCore

final class ActivityDayLedgerAllocationTests: XCTestCase {
    private static let day: Int64 = 1_800_000_000_000
    private static let denseBucketCount = 180_000
    private static let comparedSets = [
        SourceSet(.codex), SourceSet(.claudeCode), SourceSet(.gemini),
        SourceSet([.codex, .claudeCode]), .everything,
    ]

    func testEmptyLedgerPeakQueriesKeepMeasuredBucketsUnallocated() {
        var ledger = DayLedger(dayStartMs: Self.day)

        for _ in 0..<3 {
            XCTAssertEqual(ledger.measuredBucketCount, 0)
            XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
            for set in Self.comparedSets {
                XCTAssertEqual(ledger.measuredPeakOutput(for: set), 0)
            }
            XCTAssertEqual(ledger.measuredBucketCount, 0)
        }

        XCTAssertEqual(ledger.totals, .zero)
        XCTAssertTrue(ledger.bySource.isEmpty)
        XCTAssertNil(ledger.average)
        XCTAssertEqual(ledger.unfinalized, 0)
        XCTAssertEqual(ledger.cost, .zero)
        XCTAssertTrue(ledger.sourcesWithBuckets.isEmpty)
        XCTAssertEqual(ledger.subsetPeakScans, 0)
        XCTAssertEqual(ledger.subsetScannedBlocks, 0)
    }

    func testUnmeasuredRecordsKeepBucketsUnallocatedAndTotalsIntact() {
        let streaming = record("streaming", source: .claudeCode, start: Self.day + 1_000,
                               end: Self.day + 2_000, input: 7, output: 10,
                               isFinal: false, cost: 200, requestCount: 3)
        let records = [
            streaming,
            record("missing-start", source: .gemini, start: nil, end: Self.day + 3_000,
                   input: 11, output: 20, requestCount: 2),
            record("backward", start: Self.day + 5_000, end: Self.day + 4_000,
                   input: 13, output: 30, cost: 300),
            record("too-long", source: .deepseek, start: Self.day + 10_000,
                   end: Self.day + 910_001, input: 17, output: 40),
        ]
        var ledger = makeLedger(records)

        XCTAssertEqual(ledger.totals, TokenTotals(requests: 7, input: 48, output: 100))
        XCTAssertEqual(ledger.unfinalized, 3)
        XCTAssertEqual(ledger.cost, CostTally(costMicroUsd: 500, unpricedRequests: 3))
        XCTAssertNil(ledger.average)
        XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
        XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), 0)
        XCTAssertEqual(ledger.measuredBucketCount, 0)
        XCTAssertTrue(ledger.sourcesWithBuckets.isEmpty)

        let updated = record("streaming", source: .claudeCode, start: Self.day + 1_000,
                             end: Self.day + 2_500, input: 19, output: 50,
                             isFinal: false, cost: 400, requestCount: 3)
        ledger.replace(streaming, with: updated)
        XCTAssertEqual(ledger.totals, TokenTotals(requests: 7, input: 60, output: 140))
        XCTAssertEqual(ledger.unfinalized, 3)
        XCTAssertEqual(ledger.cost, CostTally(costMicroUsd: 700, unpricedRequests: 3))
        XCTAssertNil(ledger.average)
        XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
        XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), 0)
        XCTAssertEqual(ledger.measuredBucketCount, 0)
        XCTAssertEqual(ledger.subsetPeakScans, 0)
    }

    func testNonoverlappingMeasuredRecordsKeepBucketsUnallocatedAndAverage() {
        let upper = Self.day + 90_000_000
        let records = [
            record("ends-at-start", start: Self.day - 1_000, end: Self.day,
                   input: 30, output: 90, cost: 11),
            record("starts-at-end", source: .claudeCode, start: upper, end: upper + 1_000,
                   input: 70, output: 210, cost: 17),
            record("previous-day", start: Self.day - 2_000, end: Self.day - 1,
                   input: 999, output: 999),
        ]
        var ledger = makeLedger(records)

        XCTAssertEqual(ledger.totals, TokenTotals(requests: 2, input: 100, output: 300))
        XCTAssertEqual(ledger.average, 150)
        XCTAssertEqual(ledger.unfinalized, 0)
        XCTAssertEqual(ledger.cost, CostTally(costMicroUsd: 28))
        XCTAssertEqual(ledger.bySource[.codex], TokenTotals(requests: 1, input: 30, output: 90))
        XCTAssertEqual(ledger.bySource[.claudeCode], TokenTotals(requests: 1, input: 70, output: 210))
        for _ in 0..<3 {
            XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
            XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), 0)
            XCTAssertEqual(ledger.measuredBucketCount, 0)
        }
        XCTAssertTrue(ledger.sourcesWithBuckets.isEmpty)
        XCTAssertEqual(ledger.subsetPeakScans, 0)
    }

    func testFirstMeasuredRecordAllocatesDenseBucketsAndPreservesMetrics() {
        var ledger = DayLedger(dayStartMs: Self.day)
        XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
        XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), 0)
        var measured = record("measured", start: Self.day + 10_250, end: Self.day + 13_750,
                              input: 700, output: 1_400, cost: 9_876, requestCount: 2)
        measured.usage.cachedInput = 300
        measured.usage.cacheWriteInput = 100
        measured.usage.reasoning = 200
        ledger.replace(nil, with: measured)

        let expectedTotals = TokenTotals(requests: 2, input: 700, cachedInput: 300,
                                        cacheWriteInput: 100, output: 1_400, reasoning: 200)
        XCTAssertEqual(ledger.measuredBucketCount, Self.denseBucketCount)
        XCTAssertEqual(ledger.totals, expectedTotals)
        XCTAssertEqual(ledger.totals.total, 2_100)
        XCTAssertEqual(ledger.bySource, [.codex: expectedTotals])
        XCTAssertEqual(ledger.cost, CostTally(costMicroUsd: 9_876))
        XCTAssertEqual(ledger.costBySource, [.codex: CostTally(costMicroUsd: 9_876)])
        XCTAssertEqual(ledger.costByModel, [.codex: ["m": CostTally(costMicroUsd: 9_876)]])
        XCTAssertEqual(ledger.average, 400)
        XCTAssertEqual(ledger.unfinalized, 0)
        // Output buckets are [300, 400, 400, 300]; total buckets are 1.5 times those.
        let expectedPeak = DayLedger.MeasuredPeak(output: 1_100.0 / 3,
                                                 outputAtMs: Self.day + 13_000, total: 550)
        XCTAssertEqual(ledger.measuredPeak(), expectedPeak)
        XCTAssertEqual(ledger.measuredPeak(), expectedPeak)
        XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), 1_100.0 / 3)
        XCTAssertEqual(ledger.measuredPeakOutput(for: SourceSet(.codex)), 1_100.0 / 3)
        XCTAssertEqual(ledger.sourcesWithBuckets, SourceSet(.codex))
        XCTAssertEqual(ledger.measuredBucketCount, Self.denseBucketCount)
    }

    func testReplacementsAndRemovalsMatchFreshLedgerAndInvalidatePeakCaches() {
        let codex = record("codex", start: Self.day + 10_000, end: Self.day + 13_000,
                           input: 300, output: 900, cost: 100)
        let claude = record("claude", source: .claudeCode, start: Self.day + 11_000,
                            end: Self.day + 14_000, input: 300, output: 600)
        let gemini = record("gemini", source: .gemini, start: Self.day + 40_000,
                            end: Self.day + 42_000, input: 600, output: 1_200, cost: 200)
        var ledger = makeLedger([codex, claude, gemini])
        assertMatchesFresh(&ledger, records: [codex, claude, gemini])
        XCTAssertEqual(ledger.measuredPeak(), .init(output: 1_300.0 / 3,
                                                 outputAtMs: Self.day + 13_000, total: 600))
        XCTAssertEqual(ledger.subsetPeakScans, 5)
        assertMatchesFresh(&ledger, records: [codex, claude, gemini])
        XCTAssertEqual(ledger.subsetPeakScans, 5, "Repeated queries use the subset caches")

        let grown = record("codex", start: Self.day + 10_000, end: Self.day + 13_000,
                           input: 600, output: 1_800, cost: 400)
        ledger.replace(codex, with: grown)
        assertMatchesFresh(&ledger, records: [grown, claude, gemini])
        XCTAssertEqual(ledger.measuredPeak(), .init(output: 2_200.0 / 3,
                                                 outputAtMs: Self.day + 13_000, total: 1_000))
        XCTAssertEqual(ledger.subsetPeakScans, 8, "Codex, its pair and all sources are invalidated")

        ledger.replace(gemini, with: nil)
        assertMatchesFresh(&ledger, records: [grown, claude])
        XCTAssertEqual(ledger.subsetPeakScans, 10, "Only Gemini and all sources are invalidated")
        ledger.replace(grown, with: nil)
        assertMatchesFresh(&ledger, records: [claude])
        XCTAssertEqual(ledger.measuredPeak(), .init(output: 200,
                                                 outputAtMs: Self.day + 14_000, total: 300))
        XCTAssertEqual(ledger.subsetPeakScans, 13)
        ledger.replace(claude, with: nil)
        assertMatchesFresh(&ledger, records: [])
        XCTAssertEqual(ledger.measuredPeak(), DayLedger.MeasuredPeak())
        XCTAssertEqual(ledger.subsetPeakScans, 16)
        XCTAssertEqual(ledger.measuredBucketCount, Self.denseBucketCount,
                       "Allocated dense buckets are retained after the last removal")
        XCTAssertEqual(ledger.sourcesWithBuckets, SourceSet([.codex, .claudeCode, .gemini]))
        assertMatchesFresh(&ledger, records: [])
        XCTAssertEqual(ledger.subsetPeakScans, 16)
    }

    func testCopiesKeepFirstAllocationAndReplacementIndependent() {
        var empty = DayLedger(dayStartMs: Self.day)
        XCTAssertEqual(empty.measuredPeak(), DayLedger.MeasuredPeak())
        var allocated = empty
        let original = record("copy", start: Self.day + 10_000, end: Self.day + 13_000,
                              input: 300, output: 900)
        allocated.replace(nil, with: original)
        XCTAssertEqual(empty.measuredBucketCount, 0)
        assertMatchesFresh(&empty, records: [])
        XCTAssertTrue(empty.sourcesWithBuckets.isEmpty)
        XCTAssertEqual(allocated.measuredBucketCount, Self.denseBucketCount)
        assertMatchesFresh(&allocated, records: [original])

        var unchanged = allocated
        let grown = record("copy", start: Self.day + 10_000, end: Self.day + 13_000,
                           input: 600, output: 1_800)
        allocated.replace(original, with: grown)
        assertMatchesFresh(&allocated, records: [grown])
        assertMatchesFresh(&unchanged, records: [original])
        XCTAssertEqual(allocated.measuredPeak(), .init(output: 600,
                                                    outputAtMs: Self.day + 13_000, total: 800))
        XCTAssertEqual(unchanged.measuredPeak(), .init(output: 300,
                                                    outputAtMs: Self.day + 13_000, total: 400))
        XCTAssertEqual(allocated.measuredPeakOutput(for: SourceSet(.codex)), 600)
        XCTAssertEqual(unchanged.measuredPeakOutput(for: SourceSet(.codex)), 300)
        XCTAssertEqual(empty.measuredBucketCount, 0)
        XCTAssertEqual(unchanged.measuredBucketCount, Self.denseBucketCount)
    }

    func testDayBoundariesAndWidenedDurationsPreservePeakDistribution() {
        let upper = Self.day + 90_000_000
        let cases: [(String, Int64, ResponseRecord, Double, DayLedger.MeasuredPeak)] = [
            ("day-start clipping", Self.day,
             record("lower", start: Self.day - 500, end: Self.day + 500, input: 300, output: 600),
             600, .init(output: 100, outputAtMs: Self.day + 1_000, total: 150)),
            ("fractional day uses its floor second", Self.day + 250,
             record("fractional", start: Self.day - 250, end: Self.day + 250, input: 100, output: 200),
             400, .init(output: 100.0 / 3, outputAtMs: Self.day + 1_000, total: 50)),
            ("25-hour end clipping", Self.day,
             record("upper", start: upper - 1_500, end: upper + 500, input: 600, output: 1_200),
             600, .init(output: 300, outputAtMs: upper, total: 450)),
            ("zero duration widens backward to 500 ms", Self.day,
             record("zero", start: Self.day + 10_250, end: Self.day + 10_250, input: 300, output: 600),
             1_200, .init(output: 200, outputAtMs: Self.day + 11_000, total: 300)),
            ("short duration widens backward to 500 ms", Self.day,
             record("short", start: Self.day + 20_900, end: Self.day + 21_100, input: 300, output: 600),
             1_200, .init(output: 200, outputAtMs: Self.day + 22_000, total: 300)),
        ]

        for (name, dayStart, response, average, peak) in cases {
            var ledger = DayLedger(dayStartMs: dayStart)
            ledger.replace(nil, with: response)
            XCTAssertEqual(ledger.measuredBucketCount, Self.denseBucketCount, name)
            XCTAssertEqual(ledger.totals, TokenTotals(requests: 1, input: response.usage.input,
                                                     output: response.usage.output), name)
            XCTAssertEqual(ledger.average, average, name)
            XCTAssertEqual(ledger.measuredPeak(), peak, name)
            XCTAssertEqual(ledger.measuredPeakOutput(for: SourceSet(.codex)), peak.output, name)
            XCTAssertEqual(ledger.measuredPeakOutput(for: .everything), peak.output, name)
        }
    }

    private func record(_ key: String, source: SourceKind = .codex, start: Int64?, end: Int64,
                        input: Int = 0, output: Int, isFinal: Bool = true, cost: Int64? = nil,
                        requestCount: Int = 1) -> ResponseRecord {
        ResponseRecord(key: key, source: source, agentId: "\(source.rawValue)-agent", model: "m",
                       startMs: start, endMs: end, usage: TokenUsage(input: input, output: output),
                       isFinal: isFinal, costMicroUsd: cost, requestCount: requestCount)
    }

    private func makeLedger(_ records: [ResponseRecord]) -> DayLedger {
        var ledger = DayLedger(dayStartMs: Self.day)
        for record in records { ledger.replace(nil, with: record) }
        return ledger
    }

    private func assertMatchesFresh(_ ledger: inout DayLedger, records: [ResponseRecord],
                                    file: StaticString = #filePath, line: UInt = #line) {
        var fresh = makeLedger(records)
        XCTAssertEqual(ledger.totals, fresh.totals, file: file, line: line)
        XCTAssertEqual(ledger.unfinalized, fresh.unfinalized, file: file, line: line)
        XCTAssertEqual(ledger.average, fresh.average, file: file, line: line)
        XCTAssertEqual(ledger.cost, fresh.cost, file: file, line: line)
        for source in SourceKind.allCases {
            // Removal retains zero-valued dictionary entries and allocated buffers.
            XCTAssertEqual(ledger.bySource[source] ?? .zero, fresh.bySource[source] ?? .zero,
                           file: file, line: line)
            XCTAssertEqual(ledger.costBySource[source] ?? .zero, fresh.costBySource[source] ?? .zero,
                           file: file, line: line)
            let actualModels = ledger.costByModel[source] ?? [:]
            let freshModels = fresh.costByModel[source] ?? [:]
            for model in Set(actualModels.keys).union(freshModels.keys) {
                XCTAssertEqual(actualModels[model] ?? .zero, freshModels[model] ?? .zero,
                               file: file, line: line)
            }
        }
        XCTAssertEqual(ledger.measuredPeak(), fresh.measuredPeak(), file: file, line: line)
        for set in Self.comparedSets {
            XCTAssertEqual(ledger.measuredPeakOutput(for: set), fresh.measuredPeakOutput(for: set),
                           file: file, line: line)
        }
    }
}
