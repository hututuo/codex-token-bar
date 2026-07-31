import CryptoKit
import Foundation

struct TokenEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sessionID: String
    let tokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let userPrompt: String
    let assistantResponse: String
}

extension TokenEvent {
    /// Session caches only need numeric usage. Keeping excerpts here multiplies
    /// the live heap by every cached historical event after a precise scan.
    func strippingConversationExcerpt() -> TokenEvent {
        TokenEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            tokens: tokens,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            userPrompt: "",
            assistantResponse: ""
        )
    }
}

struct DayUsage: Codable, Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let tokens: Int
    let calls: Int
}

struct BinUsage: Codable, Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let tokens: Int
    let calls: Int
}

struct PluginUsage: Codable, Identifiable {
    var id: String { name }
    let name: String
    let runs: Int
}

struct TokenCacheBreakdown: Codable, Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let calls: Int

    var uncachedInputTokens: Int {
        max(inputTokens - cachedInputTokens, 0)
    }

    var nonCachedTotalTokens: Int {
        uncachedInputTokens + outputTokens
    }

    var cacheHitRate: Double {
        guard inputTokens > 0 else { return 0 }
        return Double(cachedInputTokens) / Double(inputTokens)
    }

    static let empty = TokenCacheBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0,
        calls: 0
    )
}

struct TokenCacheBucket: Codable, Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let breakdown: TokenCacheBreakdown
}

/// A sparse, source-and-bucket contribution used only by shared-account
/// attribution. Verified appends increase the same row; deleted sources remain
/// protected in the monotonic ledger; new sources in the same five-minute
/// bucket get separate rows. This avoids retaining every event in memory.
struct TokenCacheAttributionEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let start: Date
    let breakdown: TokenCacheBreakdown

    static func sourceBucket(
        provenanceEpoch: String,
        sourceID: String,
        start: Date,
        breakdown: TokenCacheBreakdown
    ) -> TokenCacheAttributionEvent {
        let identity = [
            "codex-token-bar-attribution-source-bucket-v1",
            provenanceEpoch,
            sourceID,
            String(Int64(start.timeIntervalSince1970.rounded())),
        ].joined(separator: "\u{1f}")
        let id = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return TokenCacheAttributionEvent(id: id, start: start, breakdown: breakdown)
    }
}

struct SessionCacheUsage: Codable, Identifiable {
    let id: String
    let title: String
    let lastUpdated: Date?
    let breakdown: TokenCacheBreakdown
}

struct TurnCacheUsage: Codable, Identifiable {
    let id: String
    let sessionID: String
    let sessionTitle: String
    let timestamp: Date
    let turnIndexInSession: Int
    let userPrompt: String
    let assistantResponse: String
    let breakdown: TokenCacheBreakdown

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case sessionTitle
        case timestamp
        case turnIndexInSession
        case userPrompt
        case assistantResponse
        case breakdown
    }

    init(
        id: String,
        sessionID: String,
        sessionTitle: String,
        timestamp: Date,
        turnIndexInSession: Int,
        userPrompt: String,
        assistantResponse: String,
        breakdown: TokenCacheBreakdown
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.timestamp = timestamp
        self.turnIndexInSession = turnIndexInSession
        self.userPrompt = userPrompt
        self.assistantResponse = assistantResponse
        self.breakdown = breakdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        sessionTitle = try container.decode(String.self, forKey: .sessionTitle)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        turnIndexInSession = try container.decode(Int.self, forKey: .turnIndexInSession)
        userPrompt = try container.decodeIfPresent(String.self, forKey: .userPrompt) ?? ""
        assistantResponse = try container.decodeIfPresent(String.self, forKey: .assistantResponse) ?? ""
        breakdown = try container.decode(TokenCacheBreakdown.self, forKey: .breakdown)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(sessionTitle, forKey: .sessionTitle)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(turnIndexInSession, forKey: .turnIndexInSession)
        if !userPrompt.isEmpty {
            try container.encode(userPrompt, forKey: .userPrompt)
        }
        if !assistantResponse.isEmpty {
            try container.encode(assistantResponse, forKey: .assistantResponse)
        }
        try container.encode(breakdown, forKey: .breakdown)
    }
}

struct TokenCacheUsage: Codable {
    let total: TokenCacheBreakdown
    let daily: [TokenCacheBucket]
    let hourly: [TokenCacheBucket]
    let recentBins: [TokenCacheBucket]
    let sessions: [SessionCacheUsage]
    let turns: [TurnCacheUsage]
    let attributionEvents: [TokenCacheAttributionEvent]
    /// False for old on-disk snapshots and approximate/state-SQLite results.
    /// Attribution must force a fresh exact scan before trusting event-level
    /// provenance from such a snapshot.
    let attributionEventsComplete: Bool
    /// Persistent identity of the exact-history index generation that produced
    /// these event locators. A changed epoch means prior locators cannot be
    /// reconciled safely and attribution must fail closed.
    let attributionProvenanceEpoch: String?
    /// Monotonic exact-index generation observed by this snapshot. The
    /// synthetic-cutover owner may acknowledge safety only through this exact
    /// value after its replacement segment has been durably committed.
    let attributionGeneration: Int64?
    /// Generation of the latest distinct unsafe episode in the current
    /// provenance epoch. It remains present across refreshes and cache hits;
    /// a later false-to-true episode advances it until acknowledgement.
    let attributionUnsafeSinceGeneration: Int64?
    /// True only while the most recent complete exact-index scan still sees a
    /// rewrite or unresolved lineage ambiguity. Unlike sticky unsafe state,
    /// this clears after a clean recovery scan and gates acknowledgement.
    let attributionCurrentScanUnsafeCauseDetected: Bool
    /// True when an indexed source was non-append rebuilt during this exact
    /// lineage, migration discarded prior ledger state, or lineage identity
    /// became ambiguous. Such a snapshot remains displayable, but cannot
    /// advance a positive shared-account conclusion.
    let attributionSourceMutationDetected: Bool

    init(
        total: TokenCacheBreakdown,
        daily: [TokenCacheBucket],
        hourly: [TokenCacheBucket],
        recentBins: [TokenCacheBucket],
        sessions: [SessionCacheUsage],
        turns: [TurnCacheUsage],
        attributionEvents: [TokenCacheAttributionEvent] = [],
        attributionEventsComplete: Bool = false,
        attributionProvenanceEpoch: String? = nil,
        attributionGeneration: Int64? = nil,
        attributionUnsafeSinceGeneration: Int64? = nil,
        attributionCurrentScanUnsafeCauseDetected: Bool = false,
        attributionSourceMutationDetected: Bool = false
    ) {
        self.total = total
        self.daily = daily
        self.hourly = hourly
        self.recentBins = recentBins
        self.sessions = sessions
        self.turns = turns
        self.attributionEvents = attributionEvents
        self.attributionEventsComplete = attributionEventsComplete
        self.attributionProvenanceEpoch = attributionProvenanceEpoch
        self.attributionGeneration = attributionGeneration
        self.attributionUnsafeSinceGeneration = attributionUnsafeSinceGeneration
        self.attributionCurrentScanUnsafeCauseDetected =
            attributionCurrentScanUnsafeCauseDetected
        self.attributionSourceMutationDetected = attributionSourceMutationDetected
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case daily
        case hourly
        case recentBins
        case sessions
        case turns
        case attributionEvents
        case attributionEventsComplete
        case attributionProvenanceEpoch
        case attributionGeneration
        case attributionUnsafeSinceGeneration
        case attributionCurrentScanUnsafeCauseDetected
        case attributionSourceMutationDetected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(TokenCacheBreakdown.self, forKey: .total)
        daily = try container.decode([TokenCacheBucket].self, forKey: .daily)
        hourly = try container.decode([TokenCacheBucket].self, forKey: .hourly)
        recentBins = try container.decode([TokenCacheBucket].self, forKey: .recentBins)
        sessions = try container.decode([SessionCacheUsage].self, forKey: .sessions)
        turns = try container.decode([TurnCacheUsage].self, forKey: .turns)
        attributionEvents = try container.decodeIfPresent(
            [TokenCacheAttributionEvent].self,
            forKey: .attributionEvents
        ) ?? []
        attributionEventsComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .attributionEventsComplete
        ) ?? false
        attributionProvenanceEpoch = try container.decodeIfPresent(
            String.self,
            forKey: .attributionProvenanceEpoch
        )
        attributionGeneration = try container.decodeIfPresent(
            Int64.self,
            forKey: .attributionGeneration
        )
        attributionUnsafeSinceGeneration = try container.decodeIfPresent(
            Int64.self,
            forKey: .attributionUnsafeSinceGeneration
        )
        attributionCurrentScanUnsafeCauseDetected = try container.decodeIfPresent(
            Bool.self,
            forKey: .attributionCurrentScanUnsafeCauseDetected
        ) ?? false
        attributionSourceMutationDetected = try container.decodeIfPresent(
            Bool.self,
            forKey: .attributionSourceMutationDetected
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(total, forKey: .total)
        try container.encode(daily, forKey: .daily)
        try container.encode(hourly, forKey: .hourly)
        try container.encode(recentBins, forKey: .recentBins)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(turns, forKey: .turns)
        try container.encode(attributionEvents, forKey: .attributionEvents)
        try container.encode(attributionEventsComplete, forKey: .attributionEventsComplete)
        try container.encodeIfPresent(attributionProvenanceEpoch, forKey: .attributionProvenanceEpoch)
        try container.encodeIfPresent(attributionGeneration, forKey: .attributionGeneration)
        try container.encodeIfPresent(
            attributionUnsafeSinceGeneration,
            forKey: .attributionUnsafeSinceGeneration
        )
        try container.encode(
            attributionCurrentScanUnsafeCauseDetected,
            forKey: .attributionCurrentScanUnsafeCauseDetected
        )
        try container.encode(
            attributionSourceMutationDetected,
            forKey: .attributionSourceMutationDetected
        )
    }

    static let empty = TokenCacheUsage(
        total: .empty,
        daily: [],
        hourly: [],
        recentBins: [],
        sessions: [],
        turns: [],
        attributionEvents: [],
        attributionEventsComplete: false,
        attributionProvenanceEpoch: nil,
        attributionGeneration: nil,
        attributionUnsafeSinceGeneration: nil,
        attributionCurrentScanUnsafeCauseDetected: false,
        attributionSourceMutationDetected: false
    )
}

struct QuotaHistoryDailyBucket: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let fiveHourRemainingPercent: Double?
    let sevenDayRemainingPercent: Double?
    let sampleCount: Int
}

struct QuotaHistoryRecentBucket: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let fiveHourRemainingPercent: Double?
    let sevenDayRemainingPercent: Double?
}

struct QuotaHistorySnapshot: Equatable {
    let daily: [QuotaHistoryDailyBucket]
    let recentBins: [QuotaHistoryRecentBucket]
    let hourlyBins: [QuotaHistoryRecentBucket]
    let latest: Date?

    static let empty = QuotaHistorySnapshot(daily: [], recentBins: [], hourlyBins: [], latest: nil)
}

extension Sequence where Element == TokenCacheBreakdown {
    var combined: TokenCacheBreakdown {
        reduce(.empty) { partial, breakdown in
            TokenCacheBreakdown(
                inputTokens: partial.inputTokens + breakdown.inputTokens,
                cachedInputTokens: partial.cachedInputTokens + breakdown.cachedInputTokens,
                outputTokens: partial.outputTokens + breakdown.outputTokens,
                reasoningOutputTokens: partial.reasoningOutputTokens + breakdown.reasoningOutputTokens,
                totalTokens: partial.totalTokens + breakdown.totalTokens,
                calls: partial.calls + breakdown.calls
            )
        }
    }
}

struct DashboardStats: Codable {
    let totalTokens: Int
    let peakDayTokens: Int
    let peakThreadTokens: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let totalCalls: Int
    let totalThreads: Int
    let mostUsedReasoning: String
    let skillsExplored: Int
    let totalSkillsUsed: Int
    var totalInputTokens: Int? = nil
    var totalCachedInputTokens: Int? = nil
    var totalOutputTokens: Int? = nil
    var firstUsageAt: Date? = nil
}

extension DashboardStats {
    var lifetimeTokenBreakdown: TokenCacheBreakdown {
        TokenCacheBreakdown(
            inputTokens: max(totalInputTokens ?? 0, 0),
            cachedInputTokens: min(
                max(totalCachedInputTokens ?? 0, 0),
                max(totalInputTokens ?? 0, 0)
            ),
            outputTokens: max(totalOutputTokens ?? 0, 0),
            reasoningOutputTokens: 0,
            totalTokens: totalTokens,
            calls: totalCalls
        )
    }
}

enum DashboardUsagePrecision: String, Codable, Equatable {
    case precise
    case metadataOnly

    var hasPreciseTokenUsage: Bool {
        self == .precise
    }
}

extension Double {
    var percentString: String {
        guard isFinite else { return "0%" }
        return String(format: "%.0f%%", self * 100)
    }
}

struct DashboardSnapshot: Codable {
    let stats: DashboardStats
    let dailyUsage: [DayUsage]
    let recentBins: [BinUsage]
    let hourlyUsage: [BinUsage]
    let pluginUsage: [PluginUsage]
    let cacheUsage: TokenCacheUsage
    let usagePrecision: DashboardUsagePrecision
    let preciseTimeSeriesGeneratedAt: Date?
    let generatedAt: Date

    var hasPreciseTokenUsage: Bool {
        usagePrecision.hasPreciseTokenUsage
    }

    init(
        stats: DashboardStats,
        dailyUsage: [DayUsage],
        recentBins: [BinUsage],
        hourlyUsage: [BinUsage],
        pluginUsage: [PluginUsage],
        cacheUsage: TokenCacheUsage,
        usagePrecision: DashboardUsagePrecision = .precise,
        preciseTimeSeriesGeneratedAt: Date? = nil,
        generatedAt: Date
    ) {
        self.stats = stats
        self.dailyUsage = dailyUsage
        self.recentBins = recentBins
        self.hourlyUsage = hourlyUsage
        self.pluginUsage = pluginUsage
        self.cacheUsage = cacheUsage
        self.usagePrecision = usagePrecision
        self.preciseTimeSeriesGeneratedAt = preciseTimeSeriesGeneratedAt
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case stats
        case dailyUsage
        case recentBins
        case hourlyUsage
        case pluginUsage
        case cacheUsage
        case usagePrecision
        case preciseTimeSeriesGeneratedAt
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stats = try container.decode(DashboardStats.self, forKey: .stats)
        dailyUsage = try container.decode([DayUsage].self, forKey: .dailyUsage)
        recentBins = try container.decode([BinUsage].self, forKey: .recentBins)
        hourlyUsage = try container.decode([BinUsage].self, forKey: .hourlyUsage)
        pluginUsage = try container.decode([PluginUsage].self, forKey: .pluginUsage)
        cacheUsage = try container.decode(TokenCacheUsage.self, forKey: .cacheUsage)
        usagePrecision = try container.decodeIfPresent(DashboardUsagePrecision.self, forKey: .usagePrecision) ?? .precise
        preciseTimeSeriesGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .preciseTimeSeriesGeneratedAt)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stats, forKey: .stats)
        try container.encode(dailyUsage, forKey: .dailyUsage)
        try container.encode(recentBins, forKey: .recentBins)
        try container.encode(hourlyUsage, forKey: .hourlyUsage)
        try container.encode(pluginUsage, forKey: .pluginUsage)
        try container.encode(cacheUsage, forKey: .cacheUsage)
        try container.encode(usagePrecision, forKey: .usagePrecision)
        try container.encodeIfPresent(preciseTimeSeriesGeneratedAt, forKey: .preciseTimeSeriesGeneratedAt)
        try container.encode(generatedAt, forKey: .generatedAt)
    }
}

extension Int {
    var abbreviatedTokens: String {
        let value = Double(self)
        if value >= 100_000_000 {
            return String(format: "%.1f亿", value / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", value / 10_000)
        }
        return "\(self)"
    }

    var millions: String {
        String(format: "%.1fM", Double(self) / 1_000_000)
    }
}
