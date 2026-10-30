import Combine
import Foundation

struct RecentChartPreparedSnapshot: Sendable {
    let data: RecentChartPreparedData
    let bucketCostsUSD: [Double]
    var quotaData: RecentChartPreparedData? = nil
    var costAttributionEvents: [TokenCacheAttributionEvent] = []

    func consumptionSelection(
        state: RecentChartConsumptionSelectionState,
        hoveredIndex: Int? = nil,
        priceCard: QuotaConsumptionPriceCard
    ) -> QuotaConsumptionSelection? {
        state.selection(displayedData: data, quotaData: quotaData,
            hoveredIndex: hoveredIndex, priceCard: priceCard,
            attributionEvents: costAttributionEvents)
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
        return Self(data: data,
            bucketCostsUSD: RecentUsageChart.bucketCosts(for: quotaData ?? data, priceModel: priceModel),
            quotaData: quotaData, costAttributionEvents: costEvents)
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
