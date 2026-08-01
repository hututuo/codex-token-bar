import Foundation

extension RecentUsageChart {
    static func prepare(
        range: RecentChartRange,
        recentBins: [BinUsage],
        hourlyBins: [BinUsage],
        cacheRecentBins: [TokenCacheBucket],
        cacheHourlyBins: [TokenCacheBucket],
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

    private static func usageBins(for range: RecentChartRange, recentBins: [BinUsage], hourlyBins: [BinUsage]) -> [BinUsage] {
        switch range {
        case .twentyFourHours:
            return recentBins
        case .sevenDays:
            return hourlyBins
        case .thirtyDays:
            return aggregateUsage(hourlyBins, groupSize: 3)
        }
    }

    private static func aggregateUsage(_ bins: [BinUsage], groupSize: Int) -> [BinUsage] {
        guard groupSize > 1 else { return bins }
        var result: [BinUsage] = []
        var index = 0
        while index < bins.count {
            let end = min(index + groupSize, bins.count)
            let group = bins[index..<end]
            if let start = group.first?.start {
                result.append(
                    BinUsage(
                        start: start,
                        tokens: group.reduce(0) { $0 + $1.tokens },
                        calls: group.reduce(0) { $0 + $1.calls }
                    )
                )
            }
            index = end
        }
        return result
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
                (0..<3).map { offset in
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
                let buckets = (0..<3).compactMap { offset in
                    let date = bin.start.addingTimeInterval(Double(offset) * 60 * 60)
                    return quotaByHour[timeBinKey(date, interval: 60 * 60)]
                }
                return averagedQuotaBucket(start: bin.start, buckets: buckets)
            }
        }
    }

    private static func quotaMap(_ buckets: [QuotaHistoryRecentBucket], interval: TimeInterval) -> [Int: QuotaHistoryRecentBucket] {
        Dictionary(uniqueKeysWithValues: buckets.map { bucket in
            (timeBinKey(bucket.start, interval: interval), bucket)
        })
    }

    private static func averagedQuotaBucket(start: Date, buckets: [QuotaHistoryRecentBucket]) -> QuotaHistoryRecentBucket? {
        let fiveHourValues = buckets.compactMap(\.fiveHourRemainingPercent)
        let sevenDayValues = buckets.compactMap(\.sevenDayRemainingPercent)
        let fiveHour = average(fiveHourValues)
        let sevenDay = average(sevenDayValues)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return QuotaHistoryRecentBucket(
            start: start,
            fiveHourRemainingPercent: fiveHour,
            sevenDayRemainingPercent: sevenDay,
            fiveHourObservations: buckets
                .flatMap(\.fiveHourObservations)
                .sorted { $0.observedAt < $1.observedAt },
            sevenDayObservations: buckets
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
        switch range {
        case .twentyFourHours:
            let dayStep = max(1, Int((TimeInterval(24 * 60 * 60) / bucketInterval).rounded()))
            var indices = Array(stride(from: 0, through: last, by: dayStep))
            if indices.last != last {
                indices.append(last)
            }
            return indices
        case .sevenDays, .thirtyDays:
            let weekStep = max(1, Int((TimeInterval(7 * 24 * 60 * 60) / bucketInterval).rounded()))
            var indices = Array(stride(from: 0, through: last, by: weekStep))
            if indices.last != last {
                indices.append(last)
            }
            return indices
        }
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
