import Combine
import Foundation

struct RecentChartPreparedSnapshot: Sendable {
    let data: RecentChartPreparedData
    let bucketCostsUSD: [Double]

    static func build(
        range: RecentChartRange,
        input: RecentChartPreparationInput,
        priceModel: OfficialAPIPriceModel
    ) -> Self {
        let data = RecentUsageChart.prepare(
            range: range,
            recentBins: input.bins,
            hourlyBins: input.hourlyBins,
            cacheRecentBins: input.cacheRecentBins,
            cacheHourlyBins: input.cacheHourlyBins,
            attributionEvents: input.attributionEvents,
            quotaRecentBins: input.quotaRecentBins,
            quotaHourlyBins: input.quotaHourlyBins
        )
        return Self(data: data, bucketCostsUSD: RecentUsageChart.bucketCosts(for: data, priceModel: priceModel))
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
