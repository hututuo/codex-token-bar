import Foundation

extension RecentUsageChart {
    static func prepare(
        range: RecentChartRange,
        recentBins: [BinUsage],
        hourlyBins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket],
        attributionEvents: [TokenCacheAttributionEvent] = [],
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket]
    ) -> RecentChartPreparedData {
        let bins = usageBins(for: range, recentBins: recentBins, hourlyBins: hourlyBins)
        let cacheBreakdowns = cacheBreakdowns(
            for: range,
            bins: bins,
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: cacheHourlyBins
        )
        let observedRates = observedCacheHitRates(cacheBreakdowns: cacheBreakdowns)
        let modelBreakdowns = modelBreakdowns(
            bins: bins,
            interval: range.bucketInterval,
            attributionEvents: attributionEvents
        )
        let quotaBuckets = quotaBuckets(
            for: range,
            bins: bins,
            quotaRecentBins: quotaRecentBins,
            quotaHourlyBins: quotaHourlyBins
        )
        let fiveHourRemaining = quotaBuckets.map { $0?.fiveHourRemainingPercent }
        let sevenDayRemaining = quotaBuckets.map { $0?.sevenDayRemainingPercent }
        let fiveHourObservations = quotaObservations(
            quotaBuckets,
            keyPath: \.fiveHourObservations
        )
        let sevenDayObservations = quotaObservations(
            quotaBuckets,
            keyPath: \.sevenDayObservations
        )
        let markerIndices = markerIndices(for: range, bins: bins, bucketInterval: range.bucketInterval)

        return RecentChartPreparedData(
            range: range,
            bins: bins,
            bucketInterval: range.bucketInterval,
            maxTokens: max(bins.map(\.tokens).max() ?? 1, 1),
            maxCalls: max(bins.map(\.calls).max() ?? 1, 1),
            tokenTotal: bins.reduce(0) { $0 + $1.tokens },
            callTotal: bins.reduce(0) { $0 + $1.calls },
            recentCacheBreakdown: cacheBreakdowns.combined,
            cacheBreakdowns: cacheBreakdowns,
            modelBreakdowns: modelBreakdowns,
            observedCacheHitRates: observedRates,
            fiveHourRemainingPercents: fiveHourRemaining,
            sevenDayRemainingPercents: sevenDayRemaining,
            fiveHourQuotaObservations: fiveHourObservations,
            sevenDayQuotaObservations: sevenDayObservations,
            quotaObservationProvenanceAvailable: true,
            latestFiveHourRemaining: fiveHourRemaining.reversed().compactMap { $0 }.first,
            latestSevenDayRemaining: sevenDayRemaining.reversed().compactMap { $0 }.first,
            hasCacheCalls: cacheBreakdowns.contains { $0.calls > 0 },
            hasFiveHourQuota: fiveHourRemaining.contains { $0 != nil },
            hasSevenDayQuota: sevenDayRemaining.contains { $0 != nil },
            markerIndices: markerIndices
        )
    }

    private static func modelBreakdowns(
        bins: [BinUsage],
        interval: TimeInterval,
        attributionEvents: [TokenCacheAttributionEvent]
    ) -> [[ModelTokenBreakdown]] {
        let grouped = Dictionary(grouping: attributionEvents) {
            timeBinKey($0.start, interval: interval)
        }
        return bins.map { bin in
            ModelUsagePresentation.rows(
                from: grouped[timeBinKey(bin.start, interval: interval)] ?? []
            )
        }
    }

    private static func usageBins(for range: RecentChartRange, recentBins: [BinUsage], hourlyBins: [BinUsage]) -> [BinUsage] {
        switch range {
        case .twentyFourHours:
            return recentBins
        case .sevenDays:
            return Array(hourlyBins.suffix(30 * 24))
        case .thirtyDays:
            return aggregateUsage(
                hourlyBins,
                interval: RecentChartRange.thirtyDays.bucketInterval,
                pointCount: 30 * 4
            )
        }
    }

    private static func aggregateUsage(
        _ bins: [BinUsage],
        interval: TimeInterval,
        pointCount: Int
    ) -> [BinUsage] {
        guard interval > 0, pointCount > 0, !bins.isEmpty else { return [] }
        let grouped = Dictionary(grouping: bins) {
            timeBinKey($0.start, interval: interval)
        }
        guard let endKey = grouped.keys.max() else { return [] }
        let startKey = endKey - pointCount + 1
        return (startKey...endKey).map { key in
            let group = grouped[key] ?? []
            return BinUsage(
                start: Date(timeIntervalSince1970: Double(key) * interval),
                tokens: group.reduce(0) { $0 + $1.tokens },
                calls: group.reduce(0) { $0 + $1.calls }
            )
        }
    }

    private static func cacheBreakdowns(
        for range: RecentChartRange,
        bins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket]
    ) -> [TokenCacheBreakdown] {
        switch range {
        case .twentyFourHours:
            let cacheByBin = cacheMap(cacheRecentBins, interval: 5 * 60)
            return bins.map { bin in cacheByBin[timeBinKey(bin.start, interval: 5 * 60)] ?? .empty }
        case .sevenDays:
            let cacheByHour = cacheMap(cacheHourlyBins, interval: 60 * 60)
            return bins.map { bin in cacheByHour[timeBinKey(bin.start, interval: 60 * 60)] ?? .empty }
        case .thirtyDays:
            let cacheByHour = cacheMap(cacheHourlyBins, interval: 60 * 60)
            return bins.map { bin in
                (0..<6).map { offset in
                    let date = bin.start.addingTimeInterval(Double(offset) * 60 * 60)
                    return cacheByHour[timeBinKey(date, interval: 60 * 60)] ?? .empty
                }.combined
            }
        }
    }

    private static func cacheMap(_ buckets: [TokenCacheBucket], interval: TimeInterval) -> [Int: TokenCacheBreakdown] {
        buckets.reduce(into: [Int: TokenCacheBreakdown]()) { result, bucket in
            let key = timeBinKey(bucket.start, interval: interval)
            if let current = result[key] {
                result[key] = [current, bucket.breakdown].combined
            } else {
                result[key] = bucket.breakdown
            }
        }
    }

    private static func quotaBuckets(
        for range: RecentChartRange,
        bins: [BinUsage],
        quotaRecentBins: [QuotaHistoryRecentBucket],
        quotaHourlyBins: [QuotaHistoryRecentBucket]
    ) -> [QuotaHistoryRecentBucket?] {
        switch range {
        case .twentyFourHours:
            let quotaByBin = quotaMap(quotaRecentBins, interval: 5 * 60)
            return bins.map { bin in quotaByBin[timeBinKey(bin.start, interval: 5 * 60)] }
        case .sevenDays:
            let quotaByHour = quotaMap(quotaHourlyBins, interval: 60 * 60)
            return bins.map { bin in quotaByHour[timeBinKey(bin.start, interval: 60 * 60)] }
        case .thirtyDays:
            let quotaByHour = quotaMap(quotaHourlyBins, interval: 60 * 60)
            return bins.map { bin in
                let buckets = (0..<6).compactMap { offset in
                    let date = bin.start.addingTimeInterval(Double(offset) * 60 * 60)
                    return quotaByHour[timeBinKey(date, interval: 60 * 60)]
                }
                return averagedQuotaBucket(
                    start: bin.start,
                    buckets: buckets,
                    expectedBucketCount: 6
                )
            }
        }
    }

    private static func quotaMap(_ buckets: [QuotaHistoryRecentBucket], interval: TimeInterval) -> [Int: QuotaHistoryRecentBucket] {
        Dictionary(uniqueKeysWithValues: buckets.map { bucket in
            (timeBinKey(bucket.start, interval: interval), bucket)
        })
    }

    private static func averagedQuotaBucket(
        start: Date,
        buckets: [QuotaHistoryRecentBucket],
        expectedBucketCount: Int
    ) -> QuotaHistoryRecentBucket? {
        let fiveHourValues = buckets.compactMap(\.fiveHourRemainingPercent)
        let sevenDayValues = buckets.compactMap(\.sevenDayRemainingPercent)
        // A 30d point represents six hourly buckets. If one of those
        // buckets is unknown (for example, the poller was asleep across a
        // quota reset), averaging the remaining values would turn one stale
        // carried sample into a false plateau. Keep the metric unknown until
        // every source bucket has a value; never manufacture a zero or carry
        // an old value through the gap.
        let fiveHour = fiveHourValues.count == expectedBucketCount
            ? average(fiveHourValues)
            : nil
        let sevenDay = sevenDayValues.count == expectedBucketCount
            ? average(sevenDayValues)
            : nil
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return QuotaHistoryRecentBucket(
            start: start,
            fiveHourRemainingPercent: fiveHour,
            sevenDayRemainingPercent: sevenDay,
            fiveHourObservations: fiveHour == nil
                ? []
                : buckets
                    .flatMap(\.fiveHourObservations)
                    .sorted { $0.observedAt < $1.observedAt },
            sevenDayObservations: sevenDay == nil
                ? []
                : buckets
                    .flatMap(\.sevenDayObservations)
                    .sorted { $0.observedAt < $1.observedAt }
        )
    }

    private static func quotaObservations(
        _ buckets: [QuotaHistoryRecentBucket?],
        keyPath: KeyPath<QuotaHistoryRecentBucket, [QuotaHistoryObservation]>
    ) -> [QuotaHistoryObservation] {
        let ordered = buckets
            .compactMap { $0 }
            .flatMap { $0[keyPath: keyPath] }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt {
                    return lhs.observedAt < rhs.observedAt
                }
                return lhs.remainingPercent < rhs.remainingPercent
            }
        var deduplicated: [QuotaHistoryObservation] = []
        for observation in ordered {
            if deduplicated.last?.observedAt == observation.observedAt {
                deduplicated[deduplicated.count - 1] = observation
            } else {
                deduplicated.append(observation)
            }
        }
        return deduplicated
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func timeBinKey(_ date: Date, interval: TimeInterval) -> Int {
        Int(floor(date.timeIntervalSince1970 / interval))
    }

    private static func markerIndices(for range: RecentChartRange, bins: [BinUsage], bucketInterval: TimeInterval) -> [Int] {
        guard bins.count > 1 else { return [] }

        let last = bins.count - 1
        let markerStep = max(1, Int((range.timeMarkerInterval / bucketInterval).rounded()))
        var indices = Array(stride(from: 0, through: last, by: markerStep))
        if indices.last != last {
            indices.append(last)
        }
        return indices
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private static func observedCacheHitRates(cacheBreakdowns: [TokenCacheBreakdown]) -> [Double?] {
        cacheBreakdowns.map { breakdown in
            breakdown.calls > 0 ? breakdown.cacheHitRate : nil
        }
    }
}
