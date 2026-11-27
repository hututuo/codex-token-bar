import Foundation

/// Sparse fixed-index second buckets. Pages are allocated only when a
/// measured response touches them; missing seconds remain exact zeroes.
private struct PagedDoubleBuckets: Sendable {
    static let pageSize = 256

    private let capacity: Int
    private var pages: [[Double]?]
    private(set) var allocatedValueCount = 0

    init(capacity: Int) {
        self.capacity = capacity
        pages = Array(repeating: nil, count: (capacity + Self.pageSize - 1) / Self.pageSize)
    }

    var isAllocated: Bool { allocatedValueCount > 0 }

    mutating func add(_ delta: Double, at index: Int) {
        guard index >= 0, index < capacity else { return }
        let pageIndex = index / Self.pageSize
        let start = pageIndex * Self.pageSize
        if pages[pageIndex] == nil {
            let count = min(Self.pageSize, capacity - start)
            pages[pageIndex] = Array(repeating: 0, count: count)
            allocatedValueCount += count
        }
        let offset = index - start
        pages[pageIndex]![offset] = max(0, pages[pageIndex]![offset] + delta)
    }

    func forEachAllocatedPage(pairedWith other: Self,
                              _ body: (_ start: Int, _ values: [Double], _ otherValues: [Double]) -> Void) {
        precondition(capacity == other.capacity)
        for pageIndex in pages.indices {
            let values = pages[pageIndex]
            let otherValues = other.pages[pageIndex]
            precondition((values == nil) == (otherValues == nil))
            guard let values, let otherValues else { continue }
            precondition(values.count == otherValues.count)
            body(pageIndex * Self.pageSize, values, otherValues)
        }
    }
}

/// Today's totals, average and per-second measured history (METRICS 6.6).
struct DayLedger: Sendable {
    /// Covers the longest local day (25 hours on a DST change).
    static let capacitySeconds = 25 * 3600

    let dayStartMs: Int64
    private let firstSecond: Int64
    private(set) var totals = TokenTotals()
    private(set) var bySource: [SourceKind: TokenTotals] = [:]
    /// Today's unfinalized responses (METRICS 6.6).
    private(set) var unfinalized = 0
    /// Today's cost (METRICS 9.6), in total, per source and per source and model.
    private(set) var cost = CostTally()
    private(set) var costBySource: [SourceKind: CostTally] = [:]
    private(set) var costByModel: [SourceKind: [String: CostTally]] = [:]
    private var validOutput = 0
    private var validDurationMs: Int64 = 0
    // Empty and unmeasured sources do not need 25 hours of second buckets.
    // Measured seconds allocate 256-second pages, not two dense 25-hour arrays.
    private var outputBuckets: PagedDoubleBuckets
    private var totalBuckets: PagedDoubleBuckets
    private var cachedPeak: MeasuredPeak?
    private var sourceSeconds: SourceSeconds

    struct MeasuredPeak: Equatable, Sendable {
        var output: Double = 0
        var outputAtMs: Int64?
        var total: Double = 0
    }

    init(dayStartMs: Int64) {
        self.dayStartMs = dayStartMs
        firstSecond = ResponseTiming.second(of: dayStartMs)
        outputBuckets = PagedDoubleBuckets(capacity: Self.capacitySeconds)
        totalBuckets = PagedDoubleBuckets(capacity: Self.capacitySeconds)
        sourceSeconds = SourceSeconds(firstSecond: firstSecond, capacity: Self.capacitySeconds)
    }

    func contains(_ record: ResponseRecord) -> Bool { record.endMs >= dayStartMs }

    /// Output tok/s over today's valid responses, nil when there are none.
    var average: Double? {
        guard validDurationMs > 0 else { return nil }
        return Double(validOutput) / (Double(validDurationMs) / 1000)
    }

    /// Replaces the contribution of `old` (if any) with `new` (if any).
    mutating func replace(_ old: ResponseRecord?, with new: ResponseRecord?) {
        if let old { apply(old, sign: -1) }
        if let new { apply(new, sign: 1) }
    }

    private mutating func apply(_ record: ResponseRecord, sign: Int) {
        guard contains(record) else { return }
        totals.add(record.usage, sign: sign, requestCount: record.requestCount)
        bySource[record.source, default: TokenTotals()].add(record.usage, sign: sign, requestCount: record.requestCount)
        if !record.isFinal { unfinalized += sign * record.requestCount }
        cost.add(record.costMicroUsd, sign: sign, requestCount: record.requestCount)
        costBySource[record.source, default: CostTally()].add(record.costMicroUsd, sign: sign, requestCount: record.requestCount)
        let model = record.model ?? ""
        costByModel[record.source, default: [:]][model, default: CostTally()].add(record.costMicroUsd, sign: sign, requestCount: record.requestCount)
        guard record.isFinal, let timed = TimedResponse(record) else { return }
        validOutput = validOutput.saturatingAdd(sign * record.usage.output)
        validDurationMs += Int64(sign) * timed.durationMs
        let lastSecond = firstSecond + Int64(Self.capacitySeconds) - 1
        let factor = Double(sign)
        let base = firstSecond
        if !outputBuckets.isAllocated {
            guard ResponseTiming.overlap(base * 1000, (lastSecond + 1) * 1000,
                                         timed.startMs, timed.endMs) > 0 else { return }
        }
        timed.distribute(firstSecond: base, lastSecond: lastSecond) { second, output, total in
            let index = Int(second - base)
            outputBuckets.add(factor * output, at: index)
            totalBuckets.add(factor * total, at: index)
        }
        cachedPeak = nil
        sourceSeconds.apply(timed, source: record.source, sign: sign)
    }

    /// Maximum 3-bucket trailing average of the measured one-second buckets.
    mutating func measuredPeak() -> MeasuredPeak {
        if let cachedPeak { return cachedPeak }
        var peak = MeasuredPeak()
        guard outputBuckets.isAllocated else {
            cachedPeak = peak
            return peak
        }
        var outputs = (0.0, 0.0)
        var totals = (0.0, 0.0)
        var nextIndex = 0
        outputBuckets.forEachAllocatedPage(pairedWith: totalBuckets) { start, outputPage, totalPage in
            if start != nextIndex {
                outputs = (0, 0)
                totals = (0, 0)
            }
            for offset in outputPage.indices {
                let output = outputPage[offset]
                let total = totalPage[offset]
                let outputAverage = (outputs.0 + outputs.1 + output) / 3
                let totalAverage = (totals.0 + totals.1 + total) / 3
                if outputAverage > peak.output {
                    peak.output = outputAverage
                    peak.outputAtMs = (firstSecond + Int64(start + offset) + 1) * 1000
                }
                if totalAverage > peak.total { peak.total = totalAverage }
                outputs = (outputs.1, output)
                totals = (totals.1, total)
            }
            nextIndex = start + outputPage.count
        }
        cachedPeak = peak
        return peak
    }

    /// Maximum 3-bucket trailing average of today's measured output summed over `set` (METRICS 6.8).
    mutating func measuredPeakOutput(for set: SourceSet) -> Double {
        sourceSeconds.measuredPeak(for: set)
    }

    /// Sources that have per-second buckets today.
    var sourcesWithBuckets: SourceSet { sourceSeconds.allocated }

    /// Allocated all-source bucket slots across both lanes, excluding source subsets (tests).
    var measuredBucketCount: Int { outputBuckets.allocatedValueCount + totalBuckets.allocatedValueCount }

    /// Subset peaks computed rather than answered from the cache, and the blocks they scanned (tests).
    var subsetPeakScans: Int { sourceSeconds.peakScans }
    var subsetScannedBlocks: Int { sourceSeconds.scannedBlocks }
}
