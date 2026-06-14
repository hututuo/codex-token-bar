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

struct DayUsage: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let tokens: Int
    let calls: Int
}

struct BinUsage: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let tokens: Int
    let calls: Int
}

struct PluginUsage: Identifiable {
    let id = UUID()
    let name: String
    let runs: Int
}

struct TokenCacheBreakdown: Equatable {
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

struct TokenCacheBucket: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let breakdown: TokenCacheBreakdown
}

struct SessionCacheUsage: Identifiable {
    let id: String
    let title: String
    let lastUpdated: Date?
    let breakdown: TokenCacheBreakdown
}

struct TurnCacheUsage: Identifiable {
    let id: String
    let sessionID: String
    let sessionTitle: String
    let timestamp: Date
    let turnIndexInSession: Int
    let userPrompt: String
    let assistantResponse: String
    let breakdown: TokenCacheBreakdown
}

struct TokenCacheUsage {
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

struct DashboardStats {
    let totalTokens: Int
    let peakDayTokens: Int
    let peakThreadTokens: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let totalCalls: Int
    let totalThreads: Int
    let fastModePercent: Int
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

struct DashboardSnapshot {
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
