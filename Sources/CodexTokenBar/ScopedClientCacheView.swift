import SwiftUI

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

struct ScopedClientCacheView: View, @preconcurrency Equatable {
    let codex: DashboardSnapshot
    let allowed: Set<String>
    var codexHome: URL?
    var onOpenCodexDetails: () -> Void
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @State private var showCodex = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.allowed == rhs.allowed && lhs.codex.generatedAt == rhs.codex.generatedAt && lhs.codexHome == rhs.codexHome
    }
    var body: some View {
        let coverage = ClientCacheCoverage.make(codex: codex, rows: clients.summaries, allowed: allowed)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("缓存命中排行").font(.headline)
                Spacer()
                Text("本地累计 · 可比较输入加权").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(coverage.ratio.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text("已知输入 " + MultiClientUsageStore.compact(coverage.input)).font(.caption).foregroundStyle(.secondary)
                if coverage.unknownInput > 0 {
                    Text("未参与计算 " + MultiClientUsageStore.compact(coverage.unknownInput)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("其他客户端暂无可靠的整轮排行；未提供缓存读数的请求不按未命中计算。").font(.caption).foregroundStyle(.secondary)
            if allowed.contains("codex") {
                DisclosureGroup("Codex 单轮明细", isExpanded: $showCodex) {
                    if showCodex {
                        CacheHitRankingSection(cacheUsage: codex.cacheUsage, cacheUsageRevision: codex.generatedAt,
                            codexHome: codexHome, onOpenDetails: onOpenCodexDetails)
                    }
                }
            }
        }.padding(18).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}
