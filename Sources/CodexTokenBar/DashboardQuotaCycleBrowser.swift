import SwiftUI

enum QuotaCycleHeaderPresentation {
    static func label(for cycle: QuotaActualCycle) -> String {
        let start = cycle.start.map { $0.earliest.addingTimeInterval($0.latest.timeIntervalSince($0.earliest) / 2) }
            ?? cycle.firstObservedAt
        let approximate = cycle.start?.isExact != true ? "约 " : ""
        let day = start.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        if cycle.isCurrent { return "\(approximate)\(day) 起" }
        let end = cycle.end.map { $0.earliest.addingTimeInterval($0.latest.timeIntervalSince($0.earliest) / 2) }
            ?? cycle.lastObservedAt
        let endApproximate = cycle.end?.isExact != true ? "约 " : ""
        if Calendar.current.isDate(start, inSameDayAs: end) {
            let time: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            return "\(approximate)\(day) \(start.formatted(time))–\(endApproximate)\(end.formatted(time))"
        }
        return "\(approximate)\(day)–\(endApproximate)\(end.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)))"
    }
}

struct DashboardQuotaCycleControls: View {
    let cycles: [QuotaActualCycle]
    let selected: QuotaActualCycle?
    @Binding var expanded: Bool
    let summary: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { expanded.toggle() } label: {
                Label(expanded ? "收起日历" : "历史周期", systemImage: "calendar")
                    .padding(.horizontal, 7).frame(minHeight: 28)
                    .background(AppTheme.solidControlBackground,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .accessibilityHint("选择周期，查看该周期的模型费用")
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .fixedSize()
            if let selected {
                Button { expanded.toggle() } label: {
                    Text(QuotaCycleHeaderPresentation.label(for: selected))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(minHeight: 28).contentShape(Rectangle())
                }.help(summary).foregroundStyle(.secondary)
                if !selected.isCurrent, let current = cycles.first(where: \.isCurrent) {
                    Button { onSelect(current.id) } label: {
                        Text("回到本期").frame(minHeight: 28).contentShape(Rectangle())
                    }.foregroundStyle(AppTheme.accentBlue).fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
    }
}

struct QuotaCycleUsage: Sendable {
    let rows: [ModelTokenBreakdown]
    let total: TokenCacheBreakdown
    let unassignedRows: [ModelTokenBreakdown]
    let unassignedTotal: TokenCacheBreakdown
    /// Stable source slice IDs are shared references across adjacent cycles.
    /// Their pending values must never be summed across cycle views.
    let unassignedSliceIDs: Set<String>
    var unassignedTokens: Int { unassignedTotal.totalTokens }

    /// The reader already applied exact observation boundaries, so there is
    /// no uncertain edge allocation and no token can belong to both cycles.
    init(exactEvents: [TokenCacheAttributionEvent]) {
        rows = ModelUsagePresentation.rows(from: exactEvents)
        total = exactEvents.map(\.breakdown).combined
        unassignedRows = []; unassignedTotal = .empty; unassignedSliceIDs = []
    }

    init(events: [TokenCacheAttributionEvent], cycle: QuotaActualCycle, coverageEnd: Date) {
        let certainEnd = min(cycle.certainEnd, coverageEnd)
        let outerStart = cycle.start?.earliest ?? cycle.firstObservedAt
        let outerEnd = min(cycle.end?.latest ?? cycle.lastObservedAt, coverageEnd)
        var confirmed: [TokenCacheAttributionEvent] = []
        var pending: [TokenCacheAttributionEvent] = []
        if outerEnd > outerStart {
            for slice in events.flatMap({ QuotaPeriodBoundaryPolicy.atomicSlices(for: $0) }) {
                let event = slice.event
                guard slice.end > outerStart, event.start < outerEnd else { continue }
                if certainEnd > cycle.certainStart,
                   event.start >= cycle.certainStart, slice.end <= certainEnd {
                    confirmed.append(event)
                } else {
                    pending.append(event)
                }
            }
        }
        rows = ModelUsagePresentation.rows(from: confirmed)
        total = confirmed.map(\.breakdown).combined
        unassignedRows = ModelUsagePresentation.rows(from: pending)
        unassignedTotal = pending.map(\.breakdown).combined
        unassignedSliceIDs = Set(pending.map(\.id))
    }
}

/// A precise coverage timestamp belongs to the retained attribution generation.
/// Compact headline timestamps and generations cannot extend this query.
struct QuotaCycleUsageRequest: Hashable, Sendable {
    let identity: QuotaHistoryIdentity
    let home: URL
    let cycleID: String
    let start: Date
    let end: Date
    let outerStart: Date
    let outerEnd: Date
    let coverage: Date
    let epoch: String
    let generation: Int64
    let projectionVersion: Int
    let isCurrent: Bool

    static func make(cycle: QuotaActualCycle, identity: QuotaHistoryIdentity,
                     home: URL, snapshot: DashboardSnapshot) -> Self? {
        guard identity.homeIdentity == home.standardizedFileURL.path,
              snapshot.homeIdentity.map({
                  $0 == "usage-path:\(home.standardizedFileURL.resolvingSymlinksInPath().path)"
              }) ?? true,
              snapshot.hasPreciseTokenUsage, snapshot.cacheUsage.attributionModelBucketsComplete,
              !snapshot.cacheUsage.attributionCurrentScanUnsafeCauseDetected,
              let epoch = snapshot.cacheUsage.attributionProvenanceEpoch,
              let generation = snapshot.cacheUsage.attributionGeneration,
              let coverage = snapshot.preciseTimeSeriesGeneratedAt else { return nil }
        let outerStart = cycle.start?.earliest ?? cycle.firstObservedAt
        let outerEnd = min(cycle.end?.latest ?? cycle.lastObservedAt, coverage)
        // Empty confirmed interiors still have visible, priced pending usage.
        guard outerEnd > outerStart else { return nil }
        return Self(identity: identity, home: home.standardizedFileURL, cycleID: cycle.id,
                    start: cycle.certainStart, end: min(cycle.certainEnd, coverage),
                    outerStart: outerStart, outerEnd: outerEnd, coverage: coverage,
                    epoch: epoch, generation: generation,
                    projectionVersion: QuotaActualCycleProjector.projectionVersion,
                    isCurrent: cycle.isCurrent)
    }

    func canDisplay(_ previous: Self) -> Bool {
        guard projectionVersion == QuotaActualCycleProjector.projectionVersion,
              previous.projectionVersion == projectionVersion,
              identity == previous.identity, home == previous.home,
              cycleID == previous.cycleID, epoch == previous.epoch else { return false }
        if self == previous { return true }
        // Only an expanding current cycle can retain an older result as stale.
        // A moved start, retracted coverage or finalized boundary invalidates it.
        return isCurrent && previous.isCurrent && generation >= previous.generation
            && start == previous.start && outerStart == previous.outerStart
            && end >= previous.end && outerEnd >= previous.outerEnd
            && coverage >= previous.coverage
    }

    func isCurrentResult(for snapshot: DashboardSnapshot, preciseFresh: Bool) -> Bool {
        preciseFresh && projectionVersion == QuotaActualCycleProjector.projectionVersion
            && !Self.preciseCoverageIsBehind(snapshot)
            && snapshot.cacheUsage.attributionGeneration == generation
            && snapshot.preciseTimeSeriesGeneratedAt == coverage
    }

    static func preciseCoverageIsBehind(_ snapshot: DashboardSnapshot) -> Bool {
        if let headline = snapshot.exactGeneration,
           headline != snapshot.cacheUsage.attributionGeneration { return true }
        if let observed = snapshot.observedThrough,
           let coverage = snapshot.preciseTimeSeriesGeneratedAt,
           UsageRefreshCadencePolicy.latestEligibleBoundary(now: observed) > coverage { return true }
        return false
    }

    var minuteBoundaries: [Date] {
        Array(Set([outerStart, start, end, outerEnd].filter {
            $0 >= outerStart && $0 <= outerEnd
        })).sorted()
    }

    var diagnosticDetails: String {
        "start=\(start.timeIntervalSince1970) end=\(end.timeIntervalSince1970) "
            + "outerStart=\(outerStart.timeIntervalSince1970) outerEnd=\(outerEnd.timeIntervalSince1970) "
            + "coverage=\(coverage.timeIntervalSince1970) generation=\(generation) version=\(projectionVersion)"
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
    @State private var result: QuotaCycleUsage?
    @State private var resultKey: QuotaCycleUsageRequest?
    @State private var errorText: String?
    @State private var cache: [QuotaCycleUsageRequest: QuotaCycleUsage] = [:]
    @State private var lastLoggedRequest: QuotaCycleUsageRequest?
    @State private var lastLoggedFailure: String?

    private var cycles: [QuotaActualCycle] {
        guard identity != nil, history.cycleIdentity == identity,
              history.projectionVersion == QuotaActualCycleProjector.projectionVersion else { return [] }
        return history.actualCycles
    }
    private var selected: QuotaActualCycle? { cycles.first { $0.id == selectedID } ?? cycles.first }
    private var request: QuotaCycleUsageRequest? {
        guard let selected, let identity, let codexHome else { return nil }
        return QuotaCycleUsageRequest.make(cycle: selected, identity: identity,
                                          home: codexHome, snapshot: snapshot)
    }
    private var visibleResult: QuotaCycleUsage? {
        guard let request, let resultKey, request.canDisplay(resultKey) else { return nil }
        return result
    }
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
            parts.append("\(selected.start.map { boundaryText($0) } ?? "从 \(dateText(selected.firstObservedAt)) 开始记录") → \(selected.end.map { boundaryText($0) } ?? "最近额度观测 \(dateText(selected.lastObservedAt))")")
            if selected.isCurrent, let reset = selected.scheduledResetAt { parts.append("下次重置 \(dateText(reset))") }
        } else { parts.append("暂无周期记录") }
        if let resultKey, visibleResult != nil {
            parts.append("统计截至 \(dateText(resultKey.outerEnd))")
        }
        if let value = visibleResult {
            parts.append("\(value.total.totalTokens.abbreviatedTokens) Token · 输入 \(value.total.inputTokens.abbreviatedTokens) · 缓存 \(value.total.cachedInputTokens.abbreviatedTokens) · 输出 \(value.total.outputTokens.abbreviatedTokens) · \(value.total.calls) 次")
        }
        if history.isStale { parts.append("额度周期记录待更新") }
        if let errorText { parts.append(errorText) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardModelCostRow(scope: $scope, todayRows: [], lifetimeRows: [],
                sevenDayRows: visibleResult?.rows ?? [], todayTokens: 0, lifetimeTokens: 0,
                sevenDayTokens: visibleResult?.total.totalTokens ?? 0,
                sevenDayBoundaryTokens: visibleResult?.unassignedTokens ?? 0,
                fallbackModel: fallbackModel, dataAvailable: visibleResult != nil,
                todayModelDisplayState: .pending, sevenDayDataAvailable: visibleResult != nil,
                sevenDayModelDisplayState: visibleResult == nil ? .pending : (!history.isStale && request?.isCurrentResult(for: snapshot, preciseFresh: preciseFresh) == true && resultKey == request ? .current : .stale),
                sevenDayEstimateSource: "该周期本机记录",
                sevenDayPendingRows: visibleResult?.unassignedRows ?? [],
                sevenDayStatisticsThrough: visibleResult == nil ? nil : resultKey?.outerEnd, periodLabel: selected?.isCurrent == false ? "所选周期" : "本期",
                cycles: cycles, selectedCycle: selected, cycleSummary: cycleSummary,
                onSelectCycle: { id in selectedID = cycles.first(where: { $0.id == id })?.isCurrent == true ? nil : id })
        }
        .task(id: request) { await load() }
        .onChange(of: identity) { _, _ in
            selectedID = nil; result = nil; resultKey = nil; cache.removeAll(); errorText = nil
        }
    }

    @MainActor private func load() async {
        guard let key = request, selected != nil else {
            result = nil; resultKey = nil; errorText = nil; return
        }
        errorText = nil
        if let existing = cache[key] { result = existing; resultKey = key; return }
        if resultKey.map({ !key.canDisplay($0) }) ?? true { result = nil; resultKey = nil }
        do {
            let value = try await Task.detached(priority: .utility) {
                let events = try CodexUsageHistoryIndex.quotaCycleExactUsage(codexHome: key.home,
                    provenanceEpoch: key.epoch, generation: key.generation,
                    from: key.outerStart, before: key.outerEnd)
                return QuotaCycleUsage(exactEvents: events)
            }.value
            guard !Task.isCancelled, request == key else { return }
            if cache.count >= 12 { cache.removeAll() }
            if lastLoggedRequest.map({
                $0.identity != key.identity || $0.epoch != key.epoch || $0.cycleID != key.cycleID
                    || $0.projectionVersion != key.projectionVersion || $0.start != key.start
                    || $0.outerStart != key.outerStart || $0.isCurrent != key.isCurrent
            }) ?? true {
                DiagnosticLogHistory.shared.record(summary: "周期明细重建", logs: key.diagnosticDetails, source: "quota-cycle")
            }
            lastLoggedRequest = key; lastLoggedFailure = nil
            cache[key] = value; result = value; resultKey = key
        } catch {
            guard !Task.isCancelled, request == key else { return }
            // An actual validation failure invalidates the display; normal refreshes
            // retain the same cycle until a newer committed result arrives.
            result = nil; resultKey = nil
            let failure = DiagnosticErrorDetails.text(error)
            if lastLoggedFailure != failure {
                DiagnosticLogHistory.shared.record(summary: "周期明细读取失败",
                    logs: key.diagnosticDetails + "\n" + failure, source: "quota-cycle")
                lastLoggedFailure = failure
            }
            errorText = "周期明细待更新"
        }
    }
}
