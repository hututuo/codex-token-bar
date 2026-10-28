import Foundation
import SwiftUI

/// Adapts source facts to the original dashboard contracts. Contains no views,
/// scanners or persistence; selecting a source never changes an original ledger.
enum ClientDashboardProjection {
    static func snapshot(codex: DashboardSnapshot, rows: [ClientUsageSummary],
                         trend: [ClientTrendBucket], daily: [ClientTrendBucket],
                         allowed: Set<String>, now: Date = Date()) -> DashboardSnapshot {
        guard allowed != ["codex"] else { return codex }
        let includeCodex = allowed.contains("codex")
        let selected = rows.filter { allowed.contains($0.client.rawValue) }
        let selectedTrend = trend.filter { allowed.contains($0.client.rawValue) }
        let selectedDaily = daily.filter { allowed.contains($0.client.rawValue) }
        func breakdown(_ row: ClientUsageSummary) -> TokenCacheBreakdown {
            .init(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(row.cacheReadTokens ?? 0),
                  outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0),
                  totalTokens: Int(row.inputTokens + row.outputTokens), calls: row.requests)
        }
        let total = (includeCodex ? [codex.cacheUsage.total] : []) + selected.map(breakdown)
        let combined = total.combined
        let recordedDays = ClientActivityProjection.days(codex: includeCodex ? codex.dailyUsage : [], others: selectedDaily, allowed: allowed, now: now)
        let calendar = Calendar.current
        let recordedByDate = Dictionary(grouping: recordedDays, by: { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: now)
        let days = (-364...0).compactMap { offset -> DayUsage? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let records = recordedByDate[date] ?? []
            return DayUsage(date: date, tokens: records.reduce(0) { $0 + $1.tokens }, calls: records.reduce(0) { $0 + $1.calls })
        }
        var longest = 0, current = 0, run = 0, previous: Date?
        for day in days where day.tokens > 0 {
            run = previous.flatMap { calendar.dateComponents([.day], from: $0, to: day.date).day } == 1 ? run + 1 : 1
            longest = max(longest, run); previous = day.date
        }
        if let previous, let gap = calendar.dateComponents([.day], from: previous, to: calendar.startOfDay(for: now)).day, gap <= 1 { current = run }
        func bins(_ width: Int, codexValues: [BinUsage]) -> [BinUsage] {
            var values: [Int64: (Int, Int)] = [:]
            func add(_ stamp: Int64, _ tokens: Int, _ calls: Int) {
                let key = Int64(floor(Double(stamp) / Double(width))) * Int64(width)
                let old = values[key] ?? (0, 0); values[key] = (old.0 + tokens, old.1 + calls)
            }
            if includeCodex { for row in codexValues { add(Int64(row.start.timeIntervalSince1970), row.tokens, row.calls) } }
            for row in selectedTrend { add(row.startUnix, Int(row.tokens), row.requests) }
            guard let earliest = values.keys.min() else { return [] }
            let last = Int64(floor(now.timeIntervalSince1970 / Double(width))) * Int64(width)
            let first = max(earliest, last - Int64(30 * 86400))
            return stride(from: first, through: last, by: width).map { key in
                let value = values[key] ?? (0, 0)
                return BinUsage(start: Date(timeIntervalSince1970: Double(key)), tokens: value.0, calls: value.1)
            }
        }
        let completeClients = Set(selected.filter(\.cacheReadComplete).map { $0.client.rawValue }).subtracting(selected.filter { !$0.cacheReadComplete }.map { $0.client.rawValue })
        func cacheBins(_ width: Int, codexValues: [TokenCacheBucket], source: [ClientTrendBucket]) -> [TokenCacheBucket] {
            var values: [Int64: [TokenCacheBreakdown]] = [:], unknown = Set<Int64>()
            if includeCodex { for row in codexValues { values[Int64(floor(row.start.timeIntervalSince1970 / Double(width))) * Int64(width), default: []].append(row.breakdown) } }
            for row in source {
                let key = Int64(floor(Double(row.startUnix) / Double(width))) * Int64(width)
                guard completeClients.contains(row.client.rawValue), let cached = row.cacheReadTokens else { if row.inputTokens > 0 { unknown.insert(key) }; continue }
                values[key, default: []].append(.init(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(cached), outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0), totalTokens: Int(row.tokens), calls: row.requests))
            }
            return values.filter { !unknown.contains($0.key) }.map { TokenCacheBucket(start: Date(timeIntervalSince1970: Double($0.key)), breakdown: $0.value.combined) }.sorted { $0.start < $1.start }
        }
        let models = (includeCodex ? codex.cacheUsage.modelBreakdowns : []) + selected.map { ModelTokenBreakdown(model: $0.client.displayName + " · " + $0.model, breakdown: breakdown($0)) }
        let cache = TokenCacheUsage(total: combined, modelBreakdowns: models,
            daily: cacheBins(86400, codexValues: [], source: selectedDaily),
            hourly: cacheBins(3600, codexValues: codex.cacheUsage.hourly, source: selectedTrend),
            recentBins: cacheBins(300, codexValues: codex.cacheUsage.recentBins, source: selectedTrend),
            sessions: includeCodex ? codex.cacheUsage.sessions : [], turns: includeCodex ? codex.cacheUsage.turns : [],
            attributionEventsComplete: false)
        let stats = DashboardStats(totalTokens: combined.totalTokens, peakDayTokens: days.map(\.tokens).max() ?? 0,
            peakThreadTokens: 0, currentStreakDays: current, longestStreakDays: longest,
            totalCalls: combined.calls, totalThreads: 0, mostUsedReasoning: "", skillsExplored: 0, totalSkillsUsed: 0,
            totalInputTokens: combined.inputTokens, totalCachedInputTokens: combined.cachedInputTokens,
            totalOutputTokens: combined.outputTokens, firstUsageAt: recordedDays.first?.date)
        return DashboardSnapshot(stats: stats, dailyUsage: days, recentBins: bins(300, codexValues: codex.recentBins),
            hourlyUsage: bins(3600, codexValues: codex.hourlyUsage), pluginUsage: [], cacheUsage: cache,
            usagePrecision: .precise, preciseTimeSeriesGeneratedAt: now, generatedAt: now,
            homeIdentity: "client-scope:" + allowed.sorted().joined(separator: ","), accountingCoverage: "本地已记录")
    }
}

struct ClientModelCostPeriods: Equatable {
    let lifetime: [FloatingTodayModelUsageItem]
    let today: [FloatingTodayModelUsageItem]
    let sevenDay: [FloatingTodayModelUsageItem]
    var codexPendingScopes: Set<DashboardModelCostScope> = []
    func items(_ scope: DashboardModelCostScope) -> [FloatingTodayModelUsageItem] {
        switch scope { case .lifetime: lifetime; case .today: today; case .sevenDay: sevenDay }
    }
    func groups(_ scope: DashboardModelCostScope) -> [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] {
        let values = items(scope)
        let original = values.filter { $0.id.hasPrefix("codex|") }.map { item in
            FloatingTodayModelUsageItem(id: String(item.id.dropFirst(6)), label: item.label,
                tokens: item.tokens, share: item.share, costUSD: item.costUSD, usesIndependentQuota: item.usesIndependentQuota,
                referenceCostUSD: item.referenceCostUSD, color: item.color, knownPartialCostUSD: item.knownPartialCostUSD)
        }
        let codexGroups = FloatingTodayModelUsagePresentation.dashboardFamilyGroups(from: original)
        var claudeRows = values.filter { $0.id.hasPrefix("claudeCode|") || $0.id.hasPrefix("claudeDesktop|") }
        if let first = claudeRows.first {
            let client = String(first.id.split(separator: "|")[0])
            for family in ClaudeModelPresentation.families {
                guard let model = ClaudeModelPresentation.newestCatalogModelsByFamily[family],
                      !claudeRows.contains(where: { row in
                          guard let identity = ClaudeModelPresentation.identity(row.id), identity.family == family else { return false }
                          return ClaudeModelPresentation.compare(identity.version, model.version) >= 0
                      }) else { continue }
                // Display-only availability; never appended to stored usage or cost totals.
                claudeRows.append(.init(id: client + "|" + model.id, label: ClaudeModelPresentation.identity(model.id)!.label,
                    tokens: 0, share: 0, costUSD: 0, usesIndependentQuota: false, referenceCostUSD: nil,
                    color: ModelUsagePresentation.color(for: model.id)))
            }
        }
        let claudeGroups = ClaudeModelPresentation.groups(claudeRows, client: "claude")
        let others = Dictionary(grouping: values.filter {
            !$0.id.hasPrefix("codex|") && !$0.id.hasPrefix("claudeCode|") && !$0.id.hasPrefix("claudeDesktop|")
        }, by: { String($0.id.split(separator: "|", maxSplits: 1).first ?? "") })
        let groups = codexGroups.filter { $0.id == "6" }
            + claudeGroups.filter { $0.id.hasSuffix(":latest") }
            + codexGroups.filter { $0.id != "6" }
            + claudeGroups.filter { !$0.id.hasSuffix(":latest") }
            + others.sorted { $0.key < $1.key }.map { .init(id: $0.key, title: ClientDisplayScope.title($0.key), items: $0.value) }
        return groups
    }
    static func make(codex: DashboardSnapshot, todayCodex: [ModelTokenBreakdown],
                     rows: [ClientUsageSummary], today: [ClientUsageSummary], sevenDay: [ClientUsageSummary],
                     allowed: Set<String>, now: Date = Date()) -> Self {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let recentEvents = codex.cacheUsage.attributionEvents.filter { $0.start >= cutoff && $0.start <= now }
        let recentCodex = ModelUsagePresentation.rows(from: recentEvents)
        let todayStart = Calendar.current.startOfDay(for: now)
        let indexedToday = ModelUsagePresentation.rows(from: recentEvents.filter { $0.start >= todayStart })
        let resolvedToday = todayCodex.isEmpty ? indexedToday : todayCodex
        var pending: Set<DashboardModelCostScope> = []
        if allowed.contains("codex") {
            if resolvedToday.isEmpty && codex.dailyUsage.contains(where: { $0.date >= todayStart && $0.date <= now && $0.tokens > 0 }) { pending.insert(.today) }
            if recentCodex.isEmpty && codex.recentBins.contains(where: { $0.start >= cutoff && $0.start <= now && $0.tokens > 0 }) { pending.insert(.sevenDay) }
        }
        func items(_ external: [ClientUsageSummary], _ original: [ModelTokenBreakdown]) -> [FloatingTodayModelUsageItem] {
            var result: [FloatingTodayModelUsageItem] = []
            if allowed.contains("codex") {
                result = FloatingTodayModelUsagePresentation.items(from: original, fallbackModel: .gpt56Sol, mergeAutoReview: false).map {
                    .init(id: "codex|" + $0.id, label: $0.label, tokens: $0.tokens, share: $0.share, costUSD: $0.costUSD,
                          usesIndependentQuota: $0.usesIndependentQuota, referenceCostUSD: $0.referenceCostUSD, color: $0.color, knownPartialCostUSD: $0.knownPartialCostUSD)
                }
            }
            result += external.filter { allowed.contains($0.client.rawValue) }.map { row in
                .init(id: row.client.rawValue + "|" + row.model, label: ClaudeModelPresentation.identity(row.model)?.label ?? row.model.replacingOccurrences(of: "-", with: " "),
                    tokens: Int(row.inputTokens + row.outputTokens), share: 0,
                    costUSD: row.unpricedRequests == 0 ? row.apiCostUSD : nil,
                    usesIndependentQuota: false, referenceCostUSD: nil, color: ModelUsagePresentation.color(for: row.model),
                    knownPartialCostUSD: row.unpricedRequests > 0 ? row.apiCostUSD : nil)
            }
            let total = max(1, result.reduce(0) { $0 + $1.tokens })
            return result.filter { $0.tokens > 0 }.map { .init(id: $0.id, label: $0.label, tokens: $0.tokens, share: Double($0.tokens) / Double(total), costUSD: $0.costUSD, usesIndependentQuota: $0.usesIndependentQuota, referenceCostUSD: $0.referenceCostUSD, color: $0.color, knownPartialCostUSD: $0.knownPartialCostUSD) }
        }
        return Self(lifetime: items(rows, codex.cacheUsage.modelBreakdowns), today: items(today, resolvedToday), sevenDay: items(sevenDay, recentCodex), codexPendingScopes: pending)
    }
}

/// Explicit development-only marker; never reads a persisted production setting.
enum ClientPreviewMode {
    static var simulated: Bool {
#if DEBUG
        Bundle.main.bundleIdentifier == "local.codex.token-bar.multiclient-preview"
            && ProcessInfo.processInfo.environment["TOKENBAR_DEMO_CLIENT_DATA"] == "1"
#else
        false
#endif
    }
}

@MainActor
final class ClientDashboardProjectionCache {
    private var key = ""
    private var cached: DashboardSnapshot?
    func value(codex: DashboardSnapshot, clients: MultiClientUsageStore, allowed: Set<String>) -> DashboardSnapshot {
        guard allowed != ["codex"] else { return codex }
        let nextKey = allowed.sorted().joined(separator: ",") + "|" + String(codex.generatedAt.timeIntervalSince1970)
            + "|" + String(codex.exactGeneration ?? 0) + "|" + String(clients.updatedAt?.timeIntervalSince1970 ?? 0)
        if nextKey == key, let cached { return cached }
        let result = ClientDashboardProjection.snapshot(codex: codex, rows: clients.summaries,
            trend: clients.trendBuckets, daily: clients.dailyBuckets, allowed: allowed,
            now: max(codex.generatedAt, clients.updatedAt ?? .distantPast))
        cached = result; key = nextKey
        return result
    }
}

/// One presentation result, invalidated by source generations and rolling time.
/// Hover/radar/progress publications must not reprice every historical request.
@MainActor
final class ClientModelCostPeriodsCache {
    private struct Key: Equatable {
        let source: String?
        let generation: Int64?
        let generatedAt: Date
        let clientsUpdatedAt: Date?
        let minute: Int64
        let allowed: Set<String>
        let todayCodex: [ModelTokenBreakdown]
        let attributionCount: Int
        let attributionGeneration: Int64?
        let modelBucketsComplete: Bool
    }
    private var key: Key?
    private var cached: ClientModelCostPeriods?
    private(set) var computationCount = 0
    func value(codex: DashboardSnapshot, todayCodex: [ModelTokenBreakdown],
               rows: [ClientUsageSummary], today: [ClientUsageSummary], sevenDay: [ClientUsageSummary],
               clientsUpdatedAt: Date?, allowed: Set<String>, now: Date = Date()) -> ClientModelCostPeriods {
        let next = Key(source: codex.homeIdentity, generation: codex.exactGeneration,
            generatedAt: codex.generatedAt, clientsUpdatedAt: clientsUpdatedAt,
            minute: Int64(floor(now.timeIntervalSince1970 / 60)), allowed: allowed, todayCodex: todayCodex,
            attributionCount: codex.cacheUsage.attributionEvents.count,
            attributionGeneration: codex.cacheUsage.attributionGeneration,
            modelBucketsComplete: codex.cacheUsage.attributionModelBucketsComplete)
        if next == key, let cached { return cached }
        let result = ClientModelCostPeriods.make(codex: codex, todayCodex: todayCodex,
            rows: rows, today: today, sevenDay: sevenDay, allowed: allowed, now: now)
        key = next; cached = result; computationCount += 1
        return result
    }
}
