import Foundation

/// The homepage's statistic: median of completed 5-minute weighted rates,
/// grouped into fixed half-hours (not a median of individual body samples).
struct SidebarBodyMedian: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let start: Int64
        let median: Double
        let lower: Double
        let upper: Double
        let bucketCount: Int
        let sampleCount: Int64
    }
    struct Series: Identifiable, Equatable, Sendable {
        let model: String
        let slots: [Point?]
        var id: String { model }
        var current: Point? { slots.last.flatMap { $0 } }
        var bounds: ClosedRange<Double> {
            let values = slots.compactMap { $0 }
            let low = values.map(\.lower).min() ?? 0
            let high = values.map(\.upper).max() ?? 10
            let padding = max(5, (high - low) * 0.2)
            return max(0, floor((low - padding) / 5) * 5)...max(10, ceil((high + padding) / 5) * 5)
        }
    }
    let end: Int64
    let series: [Series]
    static let width: Int64 = 1800
    static let slotCount = 6

    static func project(_ rows: [BodySpeedTrendPoint], now: Double) -> Self {
        guard now.isFinite, now >= 0, now < Double(Int64.max) - 10800 else {
            return Self(end: 0, series: [])
        }
        let end = Int64(floor(now / 1800)) * width
        let start = end - Int64(slotCount) * width
        // Store rows have a (model, bucket) primary key. Ignore malformed input;
        // repeated identical buckets must never manufacture enough observations.
        var unique: [String: [Int64: BodySpeedTrendPoint]] = [:]
        for row in rows where row.bucketStart >= start && row.bucketStart < end
            && row.bucketStart % 300 == 0 && !row.model.isEmpty
            && row.outputTokens > 0 && row.durationSeconds.isFinite && row.durationSeconds > 0
            && row.sampleCount > 0 {
            guard (Double(row.outputTokens) / row.durationSeconds).isFinite else { continue }
            unique[row.model, default: [:]][row.bucketStart] = row
        }
        let series = unique.keys.sorted().map { model in
            let groups = Dictionary(grouping: Array(unique[model]!.values)) { $0.bucketStart / width * width }
            let slots: [Point?] = (0..<slotCount).map { index in
                let at = start + Int64(index) * width
                guard let group = groups[at], group.count >= 3 else { return nil }
                var count: Int64 = 0
                for row in group {
                    let (sum, overflow) = count.addingReportingOverflow(row.sampleCount)
                    guard !overflow else { return nil }
                    count = sum
                }
                guard count >= 6 else { return nil }
                let rates = group.map { Double($0.outputTokens) / $0.durationSeconds }.sorted()
                func quantile(_ p: Double) -> Double {
                    let position = Double(rates.count - 1) * p
                    let a = Int(floor(position)), b = Int(ceil(position))
                    return rates[a] + (rates[b] - rates[a]) * (position - Double(a))
                }
                return Point(start: at, median: quantile(0.5), lower: quantile(0.25),
                             upper: quantile(0.75), bucketCount: group.count, sampleCount: count)
            }
            return Series(model: model, slots: slots)
        }
        return Self(end: end, series: series)
    }
}
