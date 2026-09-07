import Foundation

/// Defines the bucket-safe range used when a quota period starts or ends in
/// the middle of a five-minute aggregate. The aggregate does not retain
/// event-level timestamps, so a mixed edge bucket cannot be split faithfully.
/// Every complete bucket belongs to the interior; only mixed edge bucket
/// totals remain separate through `QuotaPeriodBoundaryBreakdown`.
/// Exact five-minute boundaries remain inclusive at the start and exclusive at
/// the end.
enum QuotaPeriodBoundaryPolicy {
    static let bucketDuration: TimeInterval = 5 * 60

    static func firstCompleteBucketStart(after boundary: Date) -> Date {
        let timestamp = boundary.timeIntervalSince1970
        let bucketStart = floor(timestamp / bucketDuration) * bucketDuration
        guard abs(timestamp - bucketStart) > 0.001 else {
            return Date(timeIntervalSince1970: bucketStart)
        }
        return Date(
            timeIntervalSince1970: ceil(
                timestamp / bucketDuration
            ) * bucketDuration
        )
    }

    static func lastCompleteBucketEnd(before boundary: Date) -> Date {
        let timestamp = boundary.timeIntervalSince1970
        let bucketStart = floor(timestamp / bucketDuration) * bucketDuration
        guard abs(timestamp - bucketStart) > 0.001 else {
            return Date(timeIntervalSince1970: bucketStart)
        }
        return Date(
            timeIntervalSince1970: floor(
                timestamp / bucketDuration
            ) * bucketDuration
        )
    }

    static func contains(
        bucketStart: Date,
        periodStart: Date,
        periodEnd: Date
    ) -> Bool {
        bucketStart >= firstCompleteBucketStart(after: periodStart)
            && bucketStart < lastCompleteBucketEnd(before: periodEnd)
    }
}

/// The two fixed-width buckets that touch an unaligned quota-period boundary.
///
/// The aggregate projection contains a complete value for each bucket, but it
/// cannot tell which events on either side of an in-bucket reset belong to the
/// period. Keep those values visible as independent accounting instead of
/// silently dropping them from the comparison result.
struct QuotaPeriodBoundaryBreakdown: Equatable, Sendable {
    let leading: TokenCacheBreakdown
    let trailing: TokenCacheBreakdown
    let leadingStart: Date?
    let trailingStart: Date?

    static let empty = QuotaPeriodBoundaryBreakdown(
        leading: .empty,
        trailing: .empty,
        leadingStart: nil,
        trailingStart: nil
    )

    var combined: TokenCacheBreakdown {
        [leading, trailing].combined
    }

    var totalTokens: Int {
        combined.totalTokens
    }

    var calls: Int {
        combined.calls
    }

    var hasUsage: Bool {
        totalTokens > 0
            || combined.inputTokens > 0
            || combined.outputTokens > 0
            || calls > 0
    }
}

extension QuotaPeriodBoundaryPolicy {
    /// Compatibility adapter: keep complete five-minute rows unchanged, and
    /// split only the two edge rows when exact minute detail reconciles.
    /// Missing/invalid detail retains the historical five-minute policy.
    static func partition(
        events: [TokenCacheAttributionEvent],
        periodStart: Date,
        periodEnd: Date
    ) -> (events: [TokenCacheAttributionEvent], boundary: QuotaPeriodBoundaryBreakdown) {
        guard periodEnd > periodStart else { return ([], .empty) }
        let firstMinute = ceil(periodStart.timeIntervalSince1970 / 60) * 60
        let lastMinuteEnd = floor(periodEnd.timeIntervalSince1970 / 60) * 60
        var included: [TokenCacheAttributionEvent] = []
        var leading: [TokenCacheBreakdown] = []
        var trailing: [TokenCacheBreakdown] = []
        var leadingStart: Date?
        var trailingStart: Date?
        for event in events {
            let eventEnd = event.start.addingTimeInterval(bucketDuration)
            guard eventEnd > periodStart, event.start < periodEnd else { continue }
            if event.start >= periodStart && eventEnd <= periodEnd {
                included.append(event)
                continue
            }
            let minutes = event.minuteBuckets
            let hasExactMinutes = minutes.map { values in
                !values.isEmpty
                    && Set(values.map(\.start)).count == values.count
                    && values.allSatisfy {
                        $0.start >= event.start && $0.start < eventEnd
                            && $0.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0
                            && $0.breakdown.inputTokens >= 0
                            && $0.breakdown.cachedInputTokens >= 0
                            && $0.breakdown.cachedInputTokens <= $0.breakdown.inputTokens
                            && $0.breakdown.outputTokens >= 0
                            && $0.breakdown.reasoningOutputTokens >= 0
                            && $0.breakdown.totalTokens >= 0
                            && $0.breakdown.calls >= 0
                    }
                    && values.map(\.breakdown).combined == event.breakdown
            } ?? false
            let slices = hasExactMinutes ? (minutes ?? []) : [
                TokenCacheBucket(start: event.start, breakdown: event.breakdown)
            ]
            let duration: TimeInterval = hasExactMinutes ? 60 : bucketDuration
            for slice in slices {
                let sliceEnd = slice.start.addingTimeInterval(duration)
                if hasExactMinutes,
                   slice.start.timeIntervalSince1970 >= firstMinute,
                   slice.start.timeIntervalSince1970 < lastMinuteEnd {
                    included.append(TokenCacheAttributionEvent(
                        id: "\(event.id):minute:\(Int64(slice.start.timeIntervalSince1970))",
                        start: slice.start, model: event.model, breakdown: slice.breakdown
                    ))
                } else if slice.start < periodStart && sliceEnd > periodStart {
                    leading.append(slice.breakdown)
                    leadingStart = min(leadingStart ?? slice.start, slice.start)
                } else if slice.start < periodEnd && sliceEnd > periodEnd {
                    trailing.append(slice.breakdown)
                    trailingStart = min(trailingStart ?? slice.start, slice.start)
                }
            }
        }
        return (included, QuotaPeriodBoundaryBreakdown(
            leading: leading.combined, trailing: trailing.combined,
            leadingStart: leadingStart, trailingStart: trailingStart
        ))
    }

    static func boundaryBreakdown(
        buckets: [TokenCacheBucket],
        periodStart: Date,
        periodEnd: Date,
        bucketDuration: TimeInterval = QuotaPeriodBoundaryPolicy.bucketDuration
    ) -> QuotaPeriodBoundaryBreakdown {
        boundaryBreakdown(
            values: buckets.map { ($0.start, $0.breakdown) },
            periodStart: periodStart,
            periodEnd: periodEnd,
            bucketDuration: bucketDuration
        )
    }

    static func boundaryBreakdown(
        events: [TokenCacheAttributionEvent],
        periodStart: Date,
        periodEnd: Date,
        bucketDuration: TimeInterval = QuotaPeriodBoundaryPolicy.bucketDuration
    ) -> QuotaPeriodBoundaryBreakdown {
        boundaryBreakdown(
            values: events.map { ($0.start, $0.breakdown) },
            periodStart: periodStart,
            periodEnd: periodEnd,
            bucketDuration: bucketDuration
        )
    }

    private static func boundaryBreakdown(
        values: [(Date, TokenCacheBreakdown)],
        periodStart: Date,
        periodEnd: Date,
        bucketDuration: TimeInterval
    ) -> QuotaPeriodBoundaryBreakdown {
        guard bucketDuration > 0,
              periodEnd > periodStart else {
            return .empty
        }
        let startBucket = bucketStart(for: periodStart, duration: bucketDuration)
        let endBucket = bucketStart(for: periodEnd, duration: bucketDuration)
        let leadingStart = isAligned(periodStart, to: startBucket) ? nil : startBucket
        let trailingStart: Date? = if isAligned(periodEnd, to: endBucket) || endBucket == leadingStart {
            nil
        } else {
            endBucket
        }
        func combined(at start: Date?) -> TokenCacheBreakdown {
            guard let start else { return .empty }
            return values
                .filter { $0.0 == start }
                .map(\.1)
                .combined
        }
        return QuotaPeriodBoundaryBreakdown(
            leading: combined(at: leadingStart),
            trailing: combined(at: trailingStart),
            leadingStart: leadingStart,
            trailingStart: trailingStart
        )
    }

    private static func bucketStart(for date: Date, duration: TimeInterval) -> Date {
        Date(
            timeIntervalSince1970: floor(
                date.timeIntervalSince1970 / duration
            ) * duration
        )
    }

    private static func isAligned(_ date: Date, to bucketStart: Date) -> Bool {
        abs(date.timeIntervalSince(bucketStart)) < 0.001
    }
}

/// In-memory handoff from the quota owner to background usage reads. This does
/// not persist minute rows or guess a boundary before quota has been observed.
final class QuotaPeriodBoundaryContext: @unchecked Sendable {
    static let shared = QuotaPeriodBoundaryContext()
    private let lock = NSLock()
    private var resets: [String: Date] = [:]

    func set(resetAt: Date?, home: String) {
        lock.lock()
        defer { lock.unlock() }
        resets[home] = resetAt
    }

    func bucketStarts(home: String, now: Date = Date()) -> [Date] {
        lock.lock()
        let reset = resets[home]
        lock.unlock()
        guard let reset, reset > now, reset.timeIntervalSince1970.isFinite else { return [] }
        return [reset.addingTimeInterval(-604_800), reset].compactMap { boundary in
            let bucket = floor(boundary.timeIntervalSince1970 / 300) * 300
            return abs(boundary.timeIntervalSince1970 - bucket) < 0.001
                ? nil : Date(timeIntervalSince1970: bucket)
        }
    }
}
