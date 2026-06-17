import Foundation

extension CodexUsageAnalyzer {
    func dailyUsage(from events: [TokenEvent]) -> [DayUsage] {
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -364, to: today) else { return [] }

        var grouped: [Date: (tokens: Int, calls: Int)] = [:]
        for event in events where event.timestamp >= start {
            let day = calendar.startOfDay(for: event.timestamp)
            let current = grouped[day] ?? (0, 0)
            grouped[day] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<365).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let usage = grouped[date] ?? (0, 0)
            return DayUsage(date: date, tokens: usage.tokens, calls: usage.calls)
        }
    }

    func recentBins(from events: [TokenEvent]) -> [BinUsage] {
        let end = Date()
        guard let start = calendar.date(byAdding: .hour, value: -24, to: end) else { return [] }
        let interval: TimeInterval = 5 * 60
        var grouped: [Date: (tokens: Int, calls: Int)] = [:]

        for event in events where event.timestamp >= start && event.timestamp <= end {
            let offset = floor(event.timestamp.timeIntervalSince(start) / interval)
            let bin = start.addingTimeInterval(offset * interval)
            let current = grouped[bin] ?? (0, 0)
            grouped[bin] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<288).map { index in
            let bin = start.addingTimeInterval(Double(index) * interval)
            let usage = grouped[bin] ?? (0, 0)
            return BinUsage(start: bin, tokens: usage.tokens, calls: usage.calls)
        }
    }

    func hourlyUsage(from events: [TokenEvent]) -> [BinUsage] {
        let now = Date()
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        guard let start = calendar.date(byAdding: .hour, value: -719, to: currentHour) else { return [] }
        var grouped: [Date: (tokens: Int, calls: Int)] = [:]

        for event in events where event.timestamp >= start && event.timestamp <= now {
            guard let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start else { continue }
            let current = grouped[hour] ?? (0, 0)
            grouped[hour] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<720).compactMap { index -> BinUsage? in
            guard let hour = calendar.date(byAdding: .hour, value: index, to: start) else { return nil }
            let usage = grouped[hour] ?? (0, 0)
            return BinUsage(start: hour, tokens: usage.tokens, calls: usage.calls)
        }
    }

    func cacheUsage(from events: [TokenEvent], recentBins: [BinUsage], threadInfo: [String: ThreadInfo]) -> TokenCacheUsage {
        var total = TokenCacheAccumulator()
        var daily: [Date: TokenCacheAccumulator] = [:]
        var hourly: [Date: TokenCacheAccumulator] = [:]
        var recent: [Date: TokenCacheAccumulator] = [:]
        var sessions: [String: TokenCacheAccumulator] = [:]
        var sessionLastUpdated: [String: Date] = [:]
        let recentInterval: TimeInterval = 5 * 60
        let recentStart = recentBins.first?.start
        let recentEnd = recentBins.last?.start.addingTimeInterval(recentInterval)

        for event in events {
            total.add(event)

            let day = calendar.startOfDay(for: event.timestamp)
            daily[day, default: TokenCacheAccumulator()].add(event)

            if let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start {
                hourly[hour, default: TokenCacheAccumulator()].add(event)
            }

            if let recentStart, let recentEnd,
               event.timestamp >= recentStart,
               event.timestamp <= recentEnd {
                let offset = floor(event.timestamp.timeIntervalSince(recentStart) / recentInterval)
                let bin = recentStart.addingTimeInterval(offset * recentInterval)
                recent[bin, default: TokenCacheAccumulator()].add(event)
            }

            sessions[event.sessionID, default: TokenCacheAccumulator()].add(event)
            if let current = sessionLastUpdated[event.sessionID] {
                sessionLastUpdated[event.sessionID] = max(current, event.timestamp)
            } else {
                sessionLastUpdated[event.sessionID] = event.timestamp
            }
        }

        let dailyBuckets = daily
            .map { date, accumulator in
                TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
            }
            .sorted { $0.start < $1.start }

        let hourlyBuckets = hourly
            .map { date, accumulator in
                TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
            }
            .sorted { $0.start < $1.start }

        let recentBuckets = recentBins.map { bin in
            TokenCacheBucket(start: bin.start, breakdown: (recent[bin.start] ?? TokenCacheAccumulator()).breakdown)
        }

        let sessionItems = sessions.map { sessionID, accumulator in
            let info = threadInfo[sessionID]
            return SessionCacheUsage(
                id: sessionID,
                title: info?.title ?? sessionID,
                lastUpdated: info?.updatedAt ?? sessionLastUpdated[sessionID],
                breakdown: accumulator.breakdown
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.lastUpdated, rhs.lastUpdated) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.breakdown.totalTokens > rhs.breakdown.totalTokens
            }
        }

        let orderedEvents = events.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }
        var turnIndexBySession: [String: Int] = [:]
        let turnItems = orderedEvents.map { index, event in
            let turnIndex = (turnIndexBySession[event.sessionID] ?? 0) + 1
            turnIndexBySession[event.sessionID] = turnIndex
            let info = threadInfo[event.sessionID]
            let breakdown = TokenCacheBreakdown(
                inputTokens: event.inputTokens,
                cachedInputTokens: min(event.cachedInputTokens, event.inputTokens),
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                totalTokens: event.tokens,
                calls: 1
            )
            return TurnCacheUsage(
                id: "\(event.sessionID)-\(Int(event.timestamp.timeIntervalSince1970))-\(index)",
                sessionID: event.sessionID,
                sessionTitle: info?.title ?? event.sessionID,
                timestamp: event.timestamp,
                turnIndexInSession: turnIndex,
                userPrompt: event.userPrompt,
                assistantResponse: event.assistantResponse,
                breakdown: breakdown
            )
        }
        .sorted { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }

        return TokenCacheUsage(
            total: total.breakdown,
            daily: dailyBuckets,
            hourly: hourlyBuckets,
            recentBins: recentBuckets,
            sessions: sessionItems,
            turns: turnItems
        )
    }

    func currentStreakDays(from daily: [DayUsage]) -> Int {
        var streak = 0
        for day in daily.reversed() {
            if day.tokens > 0 {
                streak += 1
            } else if streak > 0 {
                break
            }
        }
        return streak
    }

    func longestStreakDays(from daily: [DayUsage]) -> Int {
        var best = 0
        var current = 0
        for day in daily {
            if day.tokens > 0 {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    func peakSessionTokens(from events: [TokenEvent]) -> Int {
        var totals: [String: Int] = [:]
        for event in events {
            totals[event.sessionID, default: 0] += event.tokens
        }

        return totals.values.max() ?? 0
    }
}
