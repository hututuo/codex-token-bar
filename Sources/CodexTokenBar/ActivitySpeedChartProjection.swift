import Foundation

/// A single stable viewport for all models. Older lookback buckets may be
/// queried for rollups, but are never plotted outside the visible time range.
enum ActivitySpeedChartProjection {
    struct Point: Identifiable, Equatable {
        let bucketStart: Int64
        let rate: Double
        let segment: Int
        var id: Int64 { bucketStart }
    }

    static func points(_ values: [ActivitySpeedTrendPoint], now: Date, windowSeconds: Double = 1800, bucketSeconds: Int64 = 60) -> [Point] {
        let end = now.timeIntervalSince1970
        guard end.isFinite, [1800.0, 86400.0].contains(windowSeconds), [30,60].contains(bucketSeconds) else { return [] }
        var result: [Point] = []
        var previous: Int64?
        var segment = 0
        for value in values.sorted(by: { $0.bucketStart < $1.bucketStart }) {
            let stamp = Double(value.bucketStart)
            guard stamp >= end - windowSeconds, stamp <= end,
                  value.value.coveredSeconds.isFinite, value.value.coveredSeconds > 0,
                  value.value.outputRate.isFinite, value.value.outputRate >= 0 else { continue }
            if let previous, value.bucketStart - previous > bucketSeconds { segment += 1 }
            result.append(Point(bucketStart: value.bucketStart, rate: value.value.outputRate, segment: segment))
            previous = value.bucketStart
        }
        return result
    }
}
