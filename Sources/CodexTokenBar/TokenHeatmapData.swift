import SwiftUI

extension TokenHeatmap {
    static func prepare(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> HeatmapPreparedData {
        let summaries = makeSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: mode)
        let columns = makeColumnIndices(dayCount: summaries.count)
        return HeatmapPreparedData(
            summaries: summaries,
            maxTokens: max(summaries.map(\.tokens).max() ?? 1, 1),
            columns: columns,
            monthMarkers: monthMarkers(dailyUsage: dailyUsage, endColumn: max(columns.count, 1))
        )
    }

    private static func makeColumnIndices(dayCount: Int) -> [[Int]] {
        stride(from: 0, to: dayCount, by: 7).map { start in
            Array(start..<min(start + 7, dayCount))
        }
    }

    private static func makeSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket], quotaDaily: [QuotaHistoryDailyBucket], mode: ActivityMode) -> [HeatmapUsageSummary] {
        switch mode {
        case .daily:
            return dailyUsage.map { day in
                HeatmapUsageSummary(
                    title: DateFormatter.fullDay.string(from: day.date),
                    tokens: day.tokens,
                    calls: day.calls,
                    iconName: "calendar"
                )
            }
        case .weekly:
            return weeklySummaries(dailyUsage: dailyUsage)
        case .cumulative:
            var runningTokens = 0
            var runningCalls = 0
            return dailyUsage.map { day in
                runningTokens += day.tokens
                runningCalls += day.calls
                return HeatmapUsageSummary(
                    title: "截至 \(DateFormatter.fullDay.string(from: day.date))",
                    tokens: runningTokens,
                    calls: runningCalls,
                    iconName: "sum"
                )
            }
        case .cacheHitRate:
            return cacheHitRateSummaries(dailyUsage: dailyUsage, cacheDaily: cacheDaily)
        case .quotaRemaining:
            return quotaRemainingSummaries(dailyUsage: dailyUsage, quotaDaily: quotaDaily)
        }
    }

    private static func quotaRemainingSummaries(dailyUsage: [DayUsage], quotaDaily: [QuotaHistoryDailyBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let quotaByDay = Dictionary(uniqueKeysWithValues: quotaDaily.map { bucket in
            (calendar.startOfDay(for: bucket.date), bucket)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let bucket = quotaByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: Int((bucket?.sevenDayRemainingPercent ?? 0).rounded()),
                calls: bucket?.sampleCount ?? 0,
                iconName: "gauge.with.dots.needle.67percent",
                quotaRemainingPercent: bucket?.sevenDayRemainingPercent,
                isQuotaRemaining: true
            )
        }
    }

    private static func cacheHitRateSummaries(dailyUsage: [DayUsage], cacheDaily: [TokenCacheBucket]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        let cacheByDay = Dictionary(uniqueKeysWithValues: cacheDaily.map { bucket in
            (calendar.startOfDay(for: bucket.start), bucket.breakdown)
        })

        return dailyUsage.map { day in
            let date = calendar.startOfDay(for: day.date)
            let breakdown = cacheByDay[date]
            return HeatmapUsageSummary(
                title: DateFormatter.fullDay.string(from: day.date),
                tokens: breakdown?.totalTokens ?? 0,
                calls: breakdown?.calls ?? 0,
                iconName: "bolt.horizontal.circle",
                cacheBreakdown: breakdown,
                isCacheRate: true
            )
        }
    }

    private static func weeklySummaries(dailyUsage: [DayUsage]) -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        var weekTotals: [String: (tokens: Int, calls: Int, first: Date, last: Date)] = [:]

        for day in dailyUsage {
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            if let current = weekTotals[key] {
                weekTotals[key] = (
                    current.tokens + day.tokens,
                    current.calls + day.calls,
                    min(current.first, day.date),
                    max(current.last, day.date)
                )
            } else {
                weekTotals[key] = (day.tokens, day.calls, day.date, day.date)
            }
        }

        return dailyUsage.map { day in
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            let total = weekTotals[key] ?? (day.tokens, day.calls, day.date, day.date)
            return HeatmapUsageSummary(
                title: "\(DateFormatter.monthDay.string(from: total.first)) - \(DateFormatter.monthDay.string(from: total.last))",
                tokens: total.tokens,
                calls: total.calls,
                iconName: "calendar.badge.clock"
            )
        }
    }

    private static func monthMarkers(dailyUsage: [DayUsage], endColumn: Int) -> [HeatmapMonthMarker] {
        guard !dailyUsage.isEmpty else { return [] }

        var markers: [HeatmapMonthMarker] = []
        var previousMonth = -1
        let calendar = Calendar.current

        for (index, day) in dailyUsage.enumerated() {
            let month = calendar.component(.month, from: day.date)
            guard month != previousMonth else { continue }

            previousMonth = month
            let column = index / 7
            let nextColumn = nextMonthColumn(after: index, dailyUsage: dailyUsage) ?? endColumn
            markers.append(HeatmapMonthMarker(label: "\(month)月", column: column, nextColumn: nextColumn))
        }

        return markers
    }

    private static func nextMonthColumn(after index: Int, dailyUsage: [DayUsage]) -> Int? {
        guard index < dailyUsage.count else { return nil }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: dailyUsage[index].date)
        for next in (index + 1)..<dailyUsage.count {
            let nextMonth = calendar.component(.month, from: dailyUsage[next].date)
            if nextMonth != month {
                return next / 7
            }
        }
        return nil
    }
}
