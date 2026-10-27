import Foundation

struct ClientCacheCoverage: Equatable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var unknownInput: Int64 = 0
    var ratio: Double? { input > 0 ? Double(cached) / Double(input) : nil }
    static func make(codex: DashboardSnapshot, rows: [ClientUsageSummary], allowed: Set<String>) -> Self {
        var result = Self()
        if allowed.contains("codex") {
            if codex.hasPreciseTokenUsage {
                result.input += Int64(codex.cacheUsage.total.inputTokens)
                result.cached += Int64(codex.cacheUsage.total.cachedInputTokens)
            } else { result.unknownInput += Int64(codex.stats.totalInputTokens ?? 0) }
        }
        for row in rows where allowed.contains(row.client.rawValue) {
            if row.cacheReadComplete, let cached = row.cacheReadTokens, cached >= 0, cached <= row.inputTokens {
                result.input += row.inputTokens; result.cached += cached
            } else { result.unknownInput += row.inputTokens }
        }
        return result
    }
}
