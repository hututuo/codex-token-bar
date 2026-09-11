import SwiftUI

struct QuotaCycleUsage: Sendable {
    let rows: [ModelTokenBreakdown]
    let total: TokenCacheBreakdown
    let unassignedTokens: Int

    init(events: [TokenCacheAttributionEvent], cycle: QuotaActualCycle, coverageEnd: Date) {
        let inside = QuotaPeriodBoundaryPolicy.partition(events: events,
            periodStart: cycle.certainStart, periodEnd: min(cycle.certainEnd, coverageEnd))
        rows = ModelUsagePresentation.rows(from: inside.events)
        total = inside.events.map(\.breakdown).combined
        // Clip to the possible period before counting its ambiguity. Exact
        // minute detail must not label known next-cycle tokens as uncertain.
        let possible = QuotaPeriodBoundaryPolicy.partition(events: events,
            periodStart: cycle.start?.earliest ?? cycle.firstObservedAt,
            periodEnd: min(cycle.end?.latest ?? cycle.lastObservedAt, coverageEnd))
        unassignedTokens = max(0, possible.events.map(\.breakdown).combined.totalTokens
            + possible.boundary.totalTokens - total.totalTokens)
    }
}

struct DashboardQuotaCycleBrowser: View {
    @Binding var scope: DashboardModelCostScope
    let history: QuotaHistorySnapshot
    let identity: QuotaHistoryIdentity?
    let codexHome: URL?
    let snapshot: DashboardSnapshot
    let fallbackModel: OfficialAPIPriceModel
    let preciseFresh: Bool
    @State private var selectedID: String?
    @State private var calendarExpanded = false
    @State private var result: QuotaCycleUsage?
    @State private var resultKey: Request?
    @State private var errorText: String?
    @State private var cache: [Request: QuotaCycleUsage] = [:]

    private struct Request: Hashable {
        let identity: QuotaHistoryIdentity
        let home: URL
        let cycleID: String
        let start: Date
        let end: Date
        let outerStart: Date
        let outerEnd: Date
        let epoch: String
        let generation: Int64
    }
    private var cycles: [QuotaActualCycle] {
        guard identity != nil, history.cycleIdentity == identity else { return [] }
        return history.actualCycles
    }
    private var selected: QuotaActualCycle? { cycles.first { $0.id == selectedID } ?? cycles.first }
    private var previousCycle: QuotaActualCycle? {
        guard let selected, let index = cycles.firstIndex(where: { $0.id == selected.id }),
              index + 1 < cycles.count else { return nil }
        return cycles[index + 1]
    }
    private var request: Request? {
        guard let selected, let identity, let codexHome,
              identity.homeIdentity == codexHome.standardizedFileURL.path,
              snapshot.hasPreciseTokenUsage, snapshot.cacheUsage.attributionModelBucketsComplete,
              !snapshot.cacheUsage.attributionCurrentScanUnsafeCauseDetected,
              let epoch = snapshot.cacheUsage.attributionProvenanceEpoch,
              let generation = snapshot.cacheUsage.attributionGeneration,
              let coverage = snapshot.preciseTimeSeriesGeneratedAt else { return nil }
        let end = min(selected.certainEnd, coverage)
        guard end > selected.certainStart else { return nil }
        return Request(identity: identity, home: codexHome, cycleID: selected.id,
            start: selected.certainStart, end: end,
            outerStart: selected.start?.earliest ?? selected.firstObservedAt,
            outerEnd: min(selected.end?.latest ?? selected.lastObservedAt, coverage),
            epoch: epoch, generation: generation)
    }
    private var visibleResult: QuotaCycleUsage? { request == resultKey ? result : nil }
    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    private func boundaryText(_ boundary: QuotaCycleBoundary?) -> String {
        guard let boundary else { return "未知" }
        if boundary.isExact { return dateText(boundary.earliest) }
        let midpoint = boundary.earliest.addingTimeInterval(boundary.latest.timeIntervalSince(boundary.earliest) / 2)
        return "约 \(dateText(midpoint))"
    }

    private var cycleSummary: String {
        var parts: [String] = []
        if let selected {
            parts.append("\(selected.start.map { boundaryText($0) } ?? "从 \(dateText(selected.firstObservedAt)) 开始记录") → \(selected.end.map { boundaryText($0) } ?? "至今")")
            if selected.isCurrent { parts.append("计划重置 \(dateText(selected.scheduledResetAt))") }
        } else { parts.append("暂无周期记录") }
        if let value = visibleResult {
            parts.append("\(value.total.totalTokens.abbreviatedTokens) Token · 输入 \(value.total.inputTokens.abbreviatedTokens) · 缓存 \(value.total.cachedInputTokens.abbreviatedTokens) · 输出 \(value.total.outputTokens.abbreviatedTokens) · \(value.total.calls) 次")
        }
        if let errorText { parts.append(errorText) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { calendarExpanded.toggle() } label: {
                    Label(calendarExpanded ? "收起日历" : "选择周期", systemImage: calendarExpanded ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).fixedSize()
                Text(cycleSummary).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(cycleSummary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12)
            if calendarExpanded {
                QuotaCycleCalendar(cycles: cycles, selectedID: selected?.id) { selectedID = $0 }
                Text(cycleSummary).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            DashboardModelCostRow(scope: $scope, todayRows: [], lifetimeRows: [],
                sevenDayRows: visibleResult?.rows ?? [], todayTokens: 0, lifetimeTokens: 0,
                sevenDayTokens: visibleResult?.total.totalTokens ?? 0,
                sevenDayBoundaryTokens: visibleResult?.unassignedTokens ?? 0,
                fallbackModel: fallbackModel, dataAvailable: visibleResult != nil,
                todayModelDisplayState: .pending, sevenDayDataAvailable: visibleResult != nil,
                sevenDayModelDisplayState: visibleResult == nil ? .pending : (preciseFresh ? .current : .stale),
                sevenDayEstimateSource: "该周期本机记录", periodLabel: "所选周期")
        }
        .task(id: request) { await load() }
        .onChange(of: identity) { _, _ in
            selectedID = nil; result = nil; resultKey = nil; cache.removeAll(); errorText = nil
        }
    }

    @MainActor private func load() async {
        guard let key = request, let cycle = selected else {
            result = nil; resultKey = nil; errorText = nil; return
        }
        errorText = nil
        if let existing = cache[key] { result = existing; resultKey = key; return }
        result = nil; resultKey = nil
        do {
            let value = try await Task.detached(priority: .utility) {
                let start = Date(timeIntervalSince1970: floor(key.outerStart.timeIntervalSince1970 / 300) * 300)
                let end = Date(timeIntervalSince1970: ceil(key.outerEnd.timeIntervalSince1970 / 300) * 300)
                let events = try CodexUsageHistoryIndex.quotaCycleSourceBuckets(codexHome: key.home,
                    provenanceEpoch: key.epoch, generation: key.generation, from: start, before: end,
                    minuteBucketStarts: [key.start, key.end])
                return QuotaCycleUsage(events: events, cycle: cycle, coverageEnd: key.outerEnd)
            }.value
            guard !Task.isCancelled, request == key else { return }
            if cache.count >= 12 { cache.removeAll() }
            cache[key] = value; result = value; resultKey = key
        } catch {
            guard !Task.isCancelled, request == key else { return }
            errorText = "周期明细待更新"
        }
    }
}
