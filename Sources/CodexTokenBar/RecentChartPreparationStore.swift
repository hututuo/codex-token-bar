import Combine
import Foundation

struct RecentChartPreparedSnapshot: Sendable {
    let data: RecentChartPreparedData
    let bucketCostsUSD: [Double]
    let priceModel: OfficialAPIPriceModel
    var quotaData: RecentChartPreparedData? = nil
    var quotaEvidence: RecentChartPreparedData? = nil
    var costAttributionEvents: [TokenCacheAttributionEvent] = []
    var unreportedCompactionDates: [Date] = []
    var unpricedBucketRequests: [Int] = []
    var bucketHasKnownCost: [Bool] = []
    var usageBuckets: [ChartUsageSummary] = []

    func consumptionSelection(
        state: RecentChartConsumptionSelectionState,
        hoveredIndex: Int? = nil
    ) -> QuotaConsumptionSelection? {
        state.selection(displayedData: data, quotaData: quotaEvidence ?? quotaData,
            hoveredIndex: hoveredIndex, priceCard: .officialAPI(priceModel),
            attributionEvents: costAttributionEvents, unreportedCompactionDates: unreportedCompactionDates)
    }

    static func build(
        range: RecentChartRange,
        input: RecentChartPreparationInput,
        priceModel: OfficialAPIPriceModel
    ) -> Self {
        // Attribution also serves today's/live totals and intentionally contains
        // the open bucket. Chart amounts must use the closed-bucket coverage
        // of this snapshot, including when the visible axis pads an empty tail.
        func closedEvents(_ events: [TokenCacheAttributionEvent], through end: Date?) -> [TokenCacheAttributionEvent] {
            guard let end else { return events }
            return events.filter { $0.start < end }
        }
        let displayedEvents = closedEvents(input.attributionEvents, through: input.settledThrough)
        let costEvents = input.quotaCostSource.map {
            closedEvents($0.attributionEvents, through: $0.settledThrough ?? input.settledThrough)
        } ?? displayedEvents
        let data = RecentUsageChart.prepare(
            range: range,
            recentBins: input.bins,
            hourlyBins: input.hourlyBins,
            cacheRecentBins: input.cacheRecentBins,
            cacheHourlyBins: input.cacheHourlyBins,
            attributionEvents: displayedEvents,
            quotaRecentBins: input.quotaRecentBins,
            quotaHourlyBins: input.quotaHourlyBins
        )
        let quotaData: RecentChartPreparedData?
        if let source = input.quotaCostSource {
            func align(_ displayed: [BinUsage], _ original: [BinUsage]) -> [BinUsage] {
                let byTime = Dictionary(original.map { ($0.start, $0) }, uniquingKeysWith: { _, last in last })
                return displayed.map { byTime[$0.start] ?? BinUsage(start: $0.start, tokens: 0, calls: 0) }
            }
            quotaData = RecentUsageChart.prepare(range: range,
                recentBins: align(input.bins, source.bins), hourlyBins: align(input.hourlyBins, source.hourlyBins),
                cacheRecentBins: source.cacheRecentBins, cacheHourlyBins: source.cacheHourlyBins,
                attributionEvents: costEvents,
                quotaRecentBins: input.quotaRecentBins, quotaHourlyBins: input.quotaHourlyBins)
        } else if !input.includesCodexCost {
            quotaData = RecentUsageChart.prepare(range: range,
                recentBins: input.bins.map { .init(start: $0.start, tokens: 0, calls: 0) },
                hourlyBins: input.hourlyBins.map { .init(start: $0.start, tokens: 0, calls: 0) },
                cacheRecentBins: [], cacheHourlyBins: [], quotaRecentBins: [], quotaHourlyBins: [])
        } else { quotaData = nil }
        // Preserve intra-hour lows and minute attribution in the provider's
        // own snapshot. This never changes the displayed seven-day bucket size.
        var quotaEvidence: RecentChartPreparedData?
        let source = input.quotaCostSource
        let fine = source?.bins ?? input.bins
        let coarse = source?.hourlyBins ?? input.hourlyBins
        if input.includesCodexCost, range == .sevenDays, let first = fine.first, let last = fine.last,
           first.start < (coarse.suffix(30 * 24).first?.start ?? first.start).addingTimeInterval(3600),
           last.start >= (coarse.last?.start ?? last.start) {
            quotaEvidence = RecentUsageChart.prepare(range: .twentyFourHours, recentBins: fine, hourlyBins: coarse,
                cacheRecentBins: source?.cacheRecentBins ?? input.cacheRecentBins,
                cacheHourlyBins: source?.cacheHourlyBins ?? input.cacheHourlyBins,
                attributionEvents: costEvents, quotaRecentBins: input.quotaRecentBins, quotaHourlyBins: input.quotaHourlyBins)
        }
        let provider = quotaData ?? data
        let estimates = input.includesCodexCost ? RecentUsageChart.bucketPriceEstimates(for: provider, priceModel: priceModel) : []
        var costs = data.bins.indices.map { index in estimates[safe: index].map { $0.costUSD.isFinite ? max($0.costUSD, 0) : 0 } ?? 0 }
        var unknown = data.bins.indices.map { estimates[safe: $0]?.unpricedCalls ?? 0 }
        var known = data.bins.indices.map { index in input.includesCodexCost && (provider.bins[safe: index]?.calls ?? 0) > (estimates[safe: index]?.unpricedCalls ?? 0) }
        if let external = input.externalCostBuckets {
            // Feed already-priced contributions into the existing Codex scale,
            // path and hover pipeline. Quota data stays provider-specific.
            let interval = data.bucketInterval
            let grouped: [Int64: [ClientTrendBucket]] = Dictionary(grouping: external) { bucket in
                Int64(floor(Double(bucket.startUnix) / interval))
            }
            var sums: [Int64: (cost: Double, unknown: Int, known: Bool)] = [:]
            for (key, rows) in grouped {
                let cost = rows.reduce(0.0) { partial, row in
                    partial + Double(row.apiCostMicroUSD ?? 0) / 1_000_000
                }
                let unknown = rows.reduce(0) { partial, row in
                    partial + (row.apiCostMicroUSD == nil ? row.requests : row.unpricedRequests)
                }
                sums[key] = (cost: cost, unknown: unknown, known: rows.contains { $0.apiCostMicroUSD != nil })
            }
            for index in data.bins.indices {
                let value = sums[Int64(floor(data.bins[index].start.timeIntervalSince1970 / interval))]
                costs[index] += value?.cost ?? 0
                unknown[index] += value?.unknown ?? 0
                known[index] = known[index] || (value?.known ?? false)
            }
        }
        let usage = usageBuckets(display: data, codex: input.includesCodexCost ? quotaData ?? data : nil,
            external: input.externalCostBuckets ?? [], costs: costs, known: known, unknown: unknown, priceModel: priceModel)
        return Self(data: data,
            bucketCostsUSD: costs,
            priceModel: priceModel,
            quotaData: quotaData, quotaEvidence: quotaEvidence, costAttributionEvents: costEvents,
            unreportedCompactionDates: input.unreportedCompactionDates,
            unpricedBucketRequests: unknown, bucketHasKnownCost: known, usageBuckets: usage)
    }
}

/// Three bounded display snapshots for the current inputs, never a second
/// usage ledger. Build off the UI thread and publish only the active request.
@MainActor
final class RecentChartPreparationStore: ObservableObject {
    typealias Builder = @Sendable (RecentChartRange, RecentChartPreparationInput, OfficialAPIPriceModel) -> RecentChartPreparedSnapshot

    @Published private(set) var revision = 0
    private var snapshots: [RecentChartRange: RecentChartPreparedSnapshot] = [:]
    private var input: RecentChartPreparationInput?
    private var priceModel: OfficialAPIPriceModel?
    private var requestID = UUID()
    private var task: Task<Void, Never>?

    func snapshot(for range: RecentChartRange) -> RecentChartPreparedSnapshot? {
        snapshots[range]
    }

    func prepare(
        input: RecentChartPreparationInput,
        priceModel: OfficialAPIPriceModel,
        preferredRange: RecentChartRange,
        builder: @escaping Builder = RecentChartPreparedSnapshot.build
    ) {
        guard input != self.input || priceModel != self.priceModel else { return }
        task?.cancel()
        self.input = input
        self.priceModel = priceModel
        snapshots.removeAll(keepingCapacity: true)
        let requestID = UUID()
        self.requestID = requestID
        let ranges = [preferredRange] + RecentChartRange.allCases.filter { $0 != preferredRange }
        task = Task { [weak self] in
            for range in ranges {
                guard !Task.isCancelled else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    builder(range, input, priceModel)
                }
                let snapshot = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self,
                      self.requestID == requestID else { return }
                self.snapshots[range] = snapshot
                self.revision &+= 1
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        input = nil
        priceModel = nil
        snapshots.removeAll()
    }
}
