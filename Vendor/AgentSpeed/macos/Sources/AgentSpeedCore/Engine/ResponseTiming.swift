import Foundation

/// Interval rules of METRICS 3.3.
enum ResponseTiming {
    static let maxIntervalMs: Int64 = 15 * 60_000
    static let minDurationMs: Int64 = 500

    /// The widened start (`startMs'`) of a valid interval, or nil when the interval does not count as speed.
    static func effectiveStart(startMs: Int64?, endMs: Int64) -> Int64? {
        guard let startMs, endMs >= startMs, endMs - startMs <= maxIntervalMs else { return nil }
        return min(startMs, endMs - minDurationMs)
    }

    /// Length of the intersection of `[a0, a1]` and `[b0, b1]` in milliseconds.
    @inline(__always)
    static func overlap(_ a0: Int64, _ a1: Int64, _ b0: Int64, _ b1: Int64) -> Int64 {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Floor division for bucket indices.
    @inline(__always)
    static func second(of ms: Int64) -> Int64 {
        ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000)
    }
}

/// A response with a valid interval, ready for speed math.
struct TimedResponse: Sendable {
    let record: ResponseRecord
    let startMs: Int64
    var endMs: Int64 { record.endMs }
    var durationMs: Int64 { record.endMs - startMs }
    var output: Double { Double(record.usage.output) }
    var total: Double { Double(record.usage.total) }

    init?(_ record: ResponseRecord) {
        guard let start = ResponseTiming.effectiveStart(startMs: record.startMs, endMs: record.endMs) else { return nil }
        self.record = record
        startMs = start
    }

    /// Spreads output and total tokens uniformly over one-second buckets in `firstSecond...lastSecond`.
    func distribute(firstSecond: Int64, lastSecond: Int64, _ body: (_ second: Int64, _ output: Double, _ total: Double) -> Void) {
        let from = max(firstSecond, ResponseTiming.second(of: startMs))
        let to = min(lastSecond, ResponseTiming.second(of: endMs))
        guard from <= to else { return }
        let duration = Double(durationMs)
        var second = from
        while second <= to {
            let overlap = ResponseTiming.overlap(second * 1000, (second + 1) * 1000, startMs, endMs)
            if overlap > 0 {
                let share = Double(overlap) / duration
                body(second, output * share, total * share)
            }
            second += 1
        }
    }
}
