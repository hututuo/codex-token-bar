import Foundation

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
    private var outputBuckets: [Double]
    private var totalBuckets: [Double]
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
        outputBuckets = Array(repeating: 0, count: Self.capacitySeconds)
        totalBuckets = Array(repeating: 0, count: Self.capacitySeconds)
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
        outputBuckets.withUnsafeMutableBufferPointer { outputs in
            totalBuckets.withUnsafeMutableBufferPointer { totals in
                timed.distribute(firstSecond: base, lastSecond: lastSecond) { second, output, total in
                    let index = Int(second - base)
                    outputs[index] = max(0, outputs[index] + factor * output)
                    totals[index] = max(0, totals[index] + factor * total)
                }
            }
        }
        cachedPeak = nil
        sourceSeconds.apply(timed, source: record.source, sign: sign)
    }

    /// Maximum 3-bucket trailing average of the measured one-second buckets.
    mutating func measuredPeak() -> MeasuredPeak {
        if let cachedPeak { return cachedPeak }
        var peak = MeasuredPeak()
        var outputs = (0.0, 0.0)
        var totals = (0.0, 0.0)
        for index in 0..<Self.capacitySeconds {
            let output = outputBuckets[index]
            let total = totalBuckets[index]
            let outputAverage = (outputs.0 + outputs.1 + output) / 3
            let totalAverage = (totals.0 + totals.1 + total) / 3
            if outputAverage > peak.output {
                peak.output = outputAverage
                peak.outputAtMs = (firstSecond + Int64(index) + 1) * 1000
            }
            if totalAverage > peak.total { peak.total = totalAverage }
            outputs = (outputs.1, output)
            totals = (totals.1, total)
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

    /// Subset peaks computed rather than answered from the cache, and the blocks they scanned (tests).
    var subsetPeakScans: Int { sourceSeconds.peakScans }
    var subsetScannedBlocks: Int { sourceSeconds.scannedBlocks }
}
