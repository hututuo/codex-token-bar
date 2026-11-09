import Combine
import Foundation

struct RecentChartPreparedSnapshot: Sendable {
    let data: RecentChartPreparedData
    let bucketCostsUSD: [Double]
    let priceModel: OfficialAPIPriceModel
    var quotaData: RecentChartPreparedData? = nil
    var costAttributionEvents: [TokenCacheAttributionEvent] = []
    var unreportedCompactionDates: [Date] = []
    var unpricedBucketRequests: [Int] = []
    var bucketHasKnownCost: [Bool] = []

    func consumptionSelection(
        state: RecentChartConsumptionSelectionState,
        hoveredIndex: Int? = nil
    ) -> QuotaConsumptionSelection? {
        state.selection(displayedData: data, quotaData: quotaData,
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
        } else { quotaData = nil }
        var costs = input.includesCodexCost
            ? RecentUsageChart.bucketCosts(for: quotaData ?? data, priceModel: priceModel)
            : Array(repeating: 0.0, count: data.bins.count)
        var unknown = Array(repeating: 0, count: data.bins.count)
        var known = Array(repeating: input.includesCodexCost, count: data.bins.count)
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
                unknown[index] = value?.unknown ?? 0
                known[index] = known[index] || (value?.known ?? false)
            }
        }
        return Self(data: data,
            bucketCostsUSD: costs,
            priceModel: priceModel,
            quotaData: quotaData, costAttributionEvents: costEvents,
            unreportedCompactionDates: input.unreportedCompactionDates,
            unpricedBucketRequests: unknown, bucketHasKnownCost: known)
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
