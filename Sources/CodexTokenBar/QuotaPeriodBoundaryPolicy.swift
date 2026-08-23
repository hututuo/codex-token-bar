import Foundation

/// Defines the bucket-safe range used when a quota period starts or ends in
/// the middle of a five-minute aggregate. The aggregate does not retain
/// event-level timestamps, so a mixed edge bucket cannot be split faithfully.
/// We leave a one-minute margin for the comparable interior, while the edge
/// bucket totals remain available through `QuotaPeriodBoundaryBreakdown`.
/// Exact five-minute boundaries remain inclusive at the start and exclusive at
/// the end.
enum QuotaPeriodBoundaryPolicy {
    static let bucketDuration: TimeInterval = 5 * 60
    static let safetyMargin: TimeInterval = 60

    static func firstCompleteBucketStart(after boundary: Date) -> Date {
        let timestamp = boundary.timeIntervalSince1970
        let bucketStart = floor(timestamp / bucketDuration) * bucketDuration
        guard abs(timestamp - bucketStart) > 0.001 else {
            return Date(timeIntervalSince1970: bucketStart)
        }
        return Date(
            timeIntervalSince1970: ceil(
                (timestamp + safetyMargin) / bucketDuration
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
                (timestamp - safetyMargin) / bucketDuration
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
