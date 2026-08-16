import Foundation

extension CodexUsageAnalyzer {
    /// Keeps the precise scan's retained state proportional to visible UI data,
    /// rather than to the complete JSONL history.
    struct UsageAggregationBuilder {
        private static let dayCount = 365
        private static let recentBinCount = 30 * 24 * 12
        private static let recentBinInterval: TimeInterval = 5 * 60
        private static let hourCount = 365 * 24

        private let calendar: Calendar
        private let now: Date
        private let dailyStart: Date?
        private let recentStart: Date?
        private let hourlyStart: Date?

        private var total = TokenCacheAccumulator()
        private var cacheByModel: [String: TokenCacheAccumulator] = [:]
        private var cacheByDayAndModel: [DailyModelKey: TokenCacheAccumulator] = [:]
        private var dailyUsageByDate: [Date: (tokens: Int, calls: Int)] = [:]
        private var recentUsageByStart: [Date: (tokens: Int, calls: Int)] = [:]
        private var hourlyUsageByStart: [Date: (tokens: Int, calls: Int)] = [:]
        private var cacheDailyByDate: [Date: TokenCacheAccumulator] = [:]
        private var cacheHourlyByStart: [Date: TokenCacheAccumulator] = [:]
        private var cacheRecentByStart: [Date: TokenCacheAccumulator] = [:]
        private var attributionBySourceBucket: [AttributionSourceBucketKey: TokenCacheAccumulator] = [:]
        private var cacheBySession: [String: TokenCacheAccumulator] = [:]
        private var sessionLastUpdated: [String: Date] = [:]
        private var sessionIDsWithEvents = Set<String>()
        private var firstUsageAt: Date?
        private var eventCount = 0
        private var turnCandidates = TurnCandidatePools()

        init(calendar: Calendar, now: Date) {
            self.calendar = calendar
            self.now = now
            let today = calendar.startOfDay(for: now)
            dailyStart = calendar.date(byAdding: .day, value: -(Self.dayCount - 1), to: today)
            let currentRecentBinStart = Date(
                timeIntervalSince1970: floor(
                    now.timeIntervalSince1970 / Self.recentBinInterval
                ) * Self.recentBinInterval
            )
            recentStart = currentRecentBinStart.addingTimeInterval(
                -Double(Self.recentBinCount - 1) * Self.recentBinInterval
            )
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            hourlyStart = calendar.date(
                byAdding: .hour,
                value: -(Self.hourCount - 1),
                to: currentHour
            )
        }

        var totalTokens: Int {
            total.totalTokens
        }

        var totalCalls: Int {
            total.calls
        }

        var totalEventCount: Int {
            eventCount
        }

        var totalSessionCount: Int {
            sessionIDsWithEvents.count
        }

        var firstEventAt: Date? {
            firstUsageAt
        }

        var attributionCoverageStart: Date? {
            recentStart
        }

        var attributionCoverageEnd: Date? {
            recentStart?.addingTimeInterval(
                Double(Self.recentBinCount) * Self.recentBinInterval
            )
        }

        var peakSessionTokens: Int {
            cacheBySession.values.map(\.totalTokens).max() ?? 0
        }

        mutating func consume(sessionID: String, events: [TokenEvent]) {
            guard !events.isEmpty else { return }

            let globalEventOffset = eventCount
            var turnIndex = 0
            for localIndex in events.indices.sorted(by: { lhs, rhs in
                let left = events[lhs]
                let right = events[rhs]
                if left.timestamp != right.timestamp {
                    return left.timestamp < right.timestamp
                }
                return lhs < rhs
            }) {
                turnIndex += 1
                let event = events[localIndex]
                consume(
                    event,
                    stableID: "\(event.sessionID)-\(Int(event.timestamp.timeIntervalSince1970))-\(globalEventOffset + localIndex)",
                    attributionSourceID: event.sessionID,
                    turnIndexInSession: turnIndex
                )
            }
        }

        mutating func consume(
            _ event: TokenEvent,
            stableID: String,
            attributionSourceID: String? = nil,
            turnIndexInSession: Int
        ) {
            sessionIDsWithEvents.insert(event.sessionID)
            total.add(event)
            cacheByModel[event.model ?? "", default: TokenCacheAccumulator()].add(event)
            firstUsageAt = min(firstUsageAt ?? event.timestamp, event.timestamp)

            if let dailyStart, event.timestamp >= dailyStart {
                let day = calendar.startOfDay(for: event.timestamp)
                let current = dailyUsageByDate[day] ?? (0, 0)
                dailyUsageByDate[day] = (current.tokens + event.tokens, current.calls + 1)
                cacheByDayAndModel[
                    DailyModelKey(date: day, model: event.model),
                    default: TokenCacheAccumulator()
                ].add(event)
            }

            if let recentStart,
               event.timestamp >= recentStart,
               event.timestamp <= now {
                let offset = floor(event.timestamp.timeIntervalSince(recentStart) / Self.recentBinInterval)
                let start = recentStart.addingTimeInterval(offset * Self.recentBinInterval)
                let current = recentUsageByStart[start] ?? (0, 0)
                recentUsageByStart[start] = (current.tokens + event.tokens, current.calls + 1)
            }

            if let hourlyStart,
               event.timestamp >= hourlyStart,
               event.timestamp <= now,
               let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start {
                let current = hourlyUsageByStart[hour] ?? (0, 0)
                hourlyUsageByStart[hour] = (current.tokens + event.tokens, current.calls + 1)
            }

            let cacheDay = calendar.startOfDay(for: event.timestamp)
            cacheDailyByDate[cacheDay, default: TokenCacheAccumulator()].add(event)

            if let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start {
                cacheHourlyByStart[hour, default: TokenCacheAccumulator()].add(event)
            }

            if let recentStart {
                let recentEnd = recentStart.addingTimeInterval(
                    Double(Self.recentBinCount) * Self.recentBinInterval
                )
                if event.timestamp >= recentStart,
                   event.timestamp <= now,
                   event.timestamp < recentEnd {
                    let offset = floor(event.timestamp.timeIntervalSince(recentStart) / Self.recentBinInterval)
                    let start = recentStart.addingTimeInterval(offset * Self.recentBinInterval)
                    cacheRecentByStart[start, default: TokenCacheAccumulator()].add(event)
                    let sourceID = attributionSourceID ?? event.sessionID
                    attributionBySourceBucket[
                        AttributionSourceBucketKey(
                            sourceID: sourceID,
                            start: start,
                            model: event.model
                        ),
                        default: TokenCacheAccumulator()
                    ].add(event)
                }
            }

            cacheBySession[event.sessionID, default: TokenCacheAccumulator()].add(event)
            if let current = sessionLastUpdated[event.sessionID] {
                sessionLastUpdated[event.sessionID] = max(current, event.timestamp)
            } else {
                sessionLastUpdated[event.sessionID] = event.timestamp
            }

            let breakdown = TokenCacheBreakdown(
                inputTokens: event.inputTokens,
                cachedInputTokens: min(event.cachedInputTokens, event.inputTokens),
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                totalTokens: event.tokens,
                calls: 1
            )
            turnCandidates.consider(
                TurnCacheUsage(
                    id: stableID,
                    sessionID: event.sessionID,
                    sessionTitle: event.sessionID,
                    timestamp: event.timestamp,
                    turnIndexInSession: turnIndexInSession,
                    userPrompt: event.userPrompt,
                    assistantResponse: event.assistantResponse,
                    breakdown: breakdown
                )
            )
            eventCount += 1
        }

        func dailyUsage() -> [DayUsage] {
            guard let dailyStart else { return [] }
            return (0..<Self.dayCount).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: dailyStart) else {
                    return nil
                }
                let usage = dailyUsageByDate[date] ?? (0, 0)
                return DayUsage(date: date, tokens: usage.tokens, calls: usage.calls)
            }
        }

        func recentBins() -> [BinUsage] {
            guard let recentStart else { return [] }
            return (0..<Self.recentBinCount).map { index in
                let start = recentStart.addingTimeInterval(Double(index) * Self.recentBinInterval)
                let usage = recentUsageByStart[start] ?? (0, 0)
                return BinUsage(start: start, tokens: usage.tokens, calls: usage.calls)
            }
        }

        func hourlyUsage() -> [BinUsage] {
            guard let hourlyStart else { return [] }
            return (0..<Self.hourCount).compactMap { index in
                guard let start = calendar.date(byAdding: .hour, value: index, to: hourlyStart) else {
                    return nil
                }
                let usage = hourlyUsageByStart[start] ?? (0, 0)
                return BinUsage(start: start, tokens: usage.tokens, calls: usage.calls)
            }
        }

        func cacheUsage(
            recentBins: [BinUsage],
            threadInfo: [String: ThreadInfo],
            attributionProvenanceEpoch: String = "test-provenance",
            attributionGeneration: Int64? = nil,
            attributionUnsafeSinceGeneration: Int64? = nil,
            attributionCurrentScanUnsafeCauseDetected: Bool = false,
            attributionSourceMutationDetected: Bool = false,
            durableAttributionEvents: [TokenCacheAttributionEvent]? = nil
        ) -> TokenCacheUsage {
            let daily = cacheDailyByDate
                .map { date, accumulator in
                    TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
                }
                .sorted { $0.start < $1.start }
            let dailyModels = Dictionary(grouping: cacheByDayAndModel) { entry in
                entry.key.date
            }
            .map { date, entries in
                ModelTokenBucket(
                    start: date,
                    modelBreakdowns: entries.map { entry in
                        ModelTokenBreakdown(
                            model: entry.key.model,
                            breakdown: entry.value.breakdown
                        )
                    }
                    .sorted { ($0.model ?? "") < ($1.model ?? "") }
                )
            }
            .sorted { $0.start < $1.start }
            let hourly = cacheHourlyByStart
                .map { date, accumulator in
                    TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
                }
                .sorted { $0.start < $1.start }
            let recent = recentBins.map { bin in
                TokenCacheBucket(
                    start: bin.start,
                    breakdown: (cacheRecentByStart[bin.start] ?? TokenCacheAccumulator()).breakdown
                )
            }
            let sessions = cacheBySession.map { sessionID, accumulator in
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
            let turns = turnCandidates.values
                .map { turn in
                    let info = threadInfo[turn.sessionID]
                    return TurnCacheUsage(
                        id: turn.id,
                        sessionID: turn.sessionID,
                        sessionTitle: info?.title ?? turn.sessionID,
                        timestamp: turn.timestamp,
                        turnIndexInSession: turn.turnIndexInSession,
                        userPrompt: turn.userPrompt,
                        assistantResponse: turn.assistantResponse,
                        breakdown: turn.breakdown
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp {
                        return lhs.timestamp > rhs.timestamp
                    }
                    return lhs.id < rhs.id
                }
            let attributionEvents = durableAttributionEvents ?? attributionBySourceBucket.map { key, accumulator in
                TokenCacheAttributionEvent.sourceBucket(
                    provenanceEpoch: attributionProvenanceEpoch,
                    sourceID: key.sourceID,
                    start: key.start,
                    model: key.model,
                    breakdown: accumulator.breakdown
                )
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }
            return TokenCacheUsage(
                total: total.breakdown,
                modelBreakdowns: cacheByModel.map { model, accumulator in
                    ModelTokenBreakdown(
                        model: model.isEmpty ? nil : model,
                        breakdown: accumulator.breakdown
                    )
                }
                .sorted { ($0.model ?? "") < ($1.model ?? "") },
                dailyModelBreakdowns: dailyModels,
                daily: daily,
                hourly: hourly,
                recentBins: recent,
                sessions: sessions,
                turns: turns,
                attributionEvents: attributionEvents,
                attributionEventsComplete: true,
                attributionModelBucketsComplete: true,
                attributionProvenanceEpoch: attributionProvenanceEpoch,
                attributionGeneration: attributionGeneration,
                attributionUnsafeSinceGeneration: attributionUnsafeSinceGeneration,
                attributionCurrentScanUnsafeCauseDetected:
                    attributionCurrentScanUnsafeCauseDetected,
                attributionSourceMutationDetected: attributionSourceMutationDetected
            )
        }

        private struct AttributionSourceBucketKey: Hashable {
            let sourceID: String
            let start: Date
            let model: String?
        }

        private struct DailyModelKey: Hashable {
            let date: Date
            let model: String?
        }
    }
}

private extension CodexUsageAnalyzer.UsageAggregationBuilder {
    struct TurnCandidatePools {
        private static let minimumRankableInputTokens = 1_000
        private static let retainedCandidateLimit = 64

        private var latestAll: [TurnCacheUsage] = []
        private var latestNonFirst: [TurnCacheUsage] = []
        private var latestRankable: [TurnCacheUsage] = []
        private var latestRankableNonFirst: [TurnCacheUsage] = []
        private var lowHitRankable: [TurnCacheUsage] = []
        private var lowHitRankableNonFirst: [TurnCacheUsage] = []

        mutating func consider(_ candidate: TurnCacheUsage) {
            Self.insert(candidate, into: &latestAll, orderedBy: Self.latestSortsBefore)
            if candidate.turnIndexInSession > 1 {
                Self.insert(candidate, into: &latestNonFirst, orderedBy: Self.latestSortsBefore)
            }
            guard candidate.breakdown.inputTokens >= Self.minimumRankableInputTokens else {
                return
            }
            Self.insert(candidate, into: &latestRankable, orderedBy: Self.latestSortsBefore)
            Self.insert(candidate, into: &lowHitRankable, orderedBy: Self.lowHitSortsBefore)
            if candidate.turnIndexInSession > 1 {
                Self.insert(candidate, into: &latestRankableNonFirst, orderedBy: Self.latestSortsBefore)
                Self.insert(candidate, into: &lowHitRankableNonFirst, orderedBy: Self.lowHitSortsBefore)
            }
        }

        var values: [TurnCacheUsage] {
            var unique: [String: TurnCacheUsage] = [:]
            for pool in [
                latestAll,
                latestNonFirst,
                latestRankable,
                latestRankableNonFirst,
                lowHitRankable,
                lowHitRankableNonFirst
            ] {
                for candidate in pool {
                    unique[candidate.id] = candidate
                }
            }
            return Array(unique.values)
        }

        private static func insert(
            _ candidate: TurnCacheUsage,
            into pool: inout [TurnCacheUsage],
            orderedBy comparator: (TurnCacheUsage, TurnCacheUsage) -> Bool
        ) {
            pool.append(candidate)
            guard pool.count > retainedCandidateLimit * 2 else { return }
            pool.sort(by: comparator)
            pool.removeSubrange(retainedCandidateLimit..<pool.count)
        }

        private static func latestSortsBefore(_ lhs: TurnCacheUsage, _ rhs: TurnCacheUsage) -> Bool {
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.id < rhs.id
        }

        private static func lowHitSortsBefore(_ lhs: TurnCacheUsage, _ rhs: TurnCacheUsage) -> Bool {
            let leftRate = lhs.breakdown.cacheHitRate
            let rightRate = rhs.breakdown.cacheHitRate
            if abs(leftRate - rightRate) > 0.0001 {
                return leftRate < rightRate
            }
            if lhs.breakdown.uncachedInputTokens != rhs.breakdown.uncachedInputTokens {
                return lhs.breakdown.uncachedInputTokens > rhs.breakdown.uncachedInputTokens
            }
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }
}
