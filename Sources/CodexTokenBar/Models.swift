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

struct TokenCacheBreakdown: Codable, Equatable {
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

    static let empty = TokenCacheUsage(
        total: .empty,
        daily: [],
        hourly: [],
        recentBins: [],
        sessions: [],
        turns: []
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
    let generatedAt: Date
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
