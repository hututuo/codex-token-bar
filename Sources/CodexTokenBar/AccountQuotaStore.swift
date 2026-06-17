import Foundation

@MainActor
final class AccountQuotaStore: ObservableObject {
    @Published private(set) var snapshot = AccountQuotaSnapshot.empty

    private var timer: Timer?
    private weak var historyStore: QuotaHistoryStore?
    private var isRefreshing = false
    private let refreshInterval: TimeInterval = 60
    private let quotaReader: any QuotaReading

    init(quotaReader: any QuotaReading = LiveAccountQuotaReader()) {
        self.quotaReader = quotaReader
    }

    func setHistoryStore(_ historyStore: QuotaHistoryStore) {
        self.historyStore = historyStore
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        var refreshing = snapshot
        refreshing.status = snapshot.isAvailable ? "正在更新额度" : "正在读取额度"
        snapshot = refreshing

        let reader = quotaReader
        Task.detached(priority: .utility) {
            let result = await reader.readQuota()
            switch result {
            case .success(let quota):
                let previousSnapshot = await MainActor.run { self.snapshot }
                let historyStore = await MainActor.run { self.historyStore }
                let memoryAdjustedQuota = QuotaMonotonicNormalizer.normalizedSnapshot(quota, after: previousSnapshot)
                let adjustedQuota = await historyStore?.normalizedForDisplay(memoryAdjustedQuota) ?? memoryAdjustedQuota

                await MainActor.run {
                    self.isRefreshing = false
                    self.snapshot = adjustedQuota
                    self.historyStore?.record(adjustedQuota)
                }
            case .failure(let error):
                await MainActor.run {
                    self.isRefreshing = false
                    var failed = self.snapshot
                    failed.status = "额度读取失败：\(error.localizedDescription)"
                    self.snapshot = failed
                }
            }
        }
    }
}
