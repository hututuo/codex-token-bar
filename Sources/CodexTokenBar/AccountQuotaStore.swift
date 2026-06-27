import Foundation

@MainActor
final class AccountQuotaStore: ObservableObject {
    @Published private(set) var snapshot = AccountQuotaSnapshot.empty

    private var timer: Timer?
    private weak var historyStore: QuotaHistoryStore?
    private var isRefreshing = false
    private var lastSuccessfulRefreshCompletedAt: Date?
    private let refreshInterval: TimeInterval = 60
    private let automaticRefreshCooldown: TimeInterval = 30
    private let quotaReader: any QuotaReading

    init(quotaReader: any QuotaReading = LiveAccountQuotaReader()) {
        self.quotaReader = quotaReader
    }

    func setHistoryStore(_ historyStore: QuotaHistoryStore) {
        self.historyStore = historyStore
    }

    func start() {
        guard timer == nil else { return }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = true) {
        let recentSuccessAge = lastSuccessfulRefreshCompletedAt.map { Date().timeIntervalSince($0) }
        let trace = RefreshPerformanceProbe.begin("quotaStore.refresh", metadata: [
            "alreadyRefreshing": isRefreshing ? "1" : "0",
            "available": snapshot.isAvailable ? "1" : "0",
            "force": force ? "1" : "0",
            "recentSuccessAge": recentSuccessAge.map { String(format: "%.2f", $0) } ?? "nil"
        ])
        guard !isRefreshing else {
            trace?.end("skipped-refresh-in-flight")
            return
        }
        if !force,
           snapshot.isAvailable,
           let recentSuccessAge,
           recentSuccessAge < automaticRefreshCooldown {
            trace?.end("skipped-recent-success", metadata: [
                "cooldown": String(format: "%.2f", automaticRefreshCooldown)
            ])
            return
        }
        isRefreshing = true
        var refreshing = snapshot
        refreshing.status = snapshot.isAvailable ? "正在更新额度" : "正在读取额度"
        snapshot = refreshing

        let reader = quotaReader
        Task.detached(priority: .utility) {
            trace?.mark("reader.begin")
            let result = await reader.readQuota()
            trace?.mark("reader.end")
            switch result {
            case .success(let quota):
                trace?.mark("mainActor.previousSnapshot.begin")
                let previousSnapshot = await MainActor.run { self.snapshot }
                trace?.mark("mainActor.previousSnapshot.end")
                trace?.mark("mainActor.historyStore.begin")
                let historyStore = await MainActor.run { self.historyStore }
                trace?.mark("mainActor.historyStore.end")
                trace?.mark("memoryNormalize.begin")
                let memoryAdjustedQuota = QuotaMonotonicNormalizer.normalizedSnapshot(quota, after: previousSnapshot)
                trace?.mark("memoryNormalize.end")
                trace?.mark("historyNormalize.begin")
                let adjustedQuota = await historyStore?.normalizedForDisplay(memoryAdjustedQuota) ?? memoryAdjustedQuota
                trace?.mark("historyNormalize.end", metadata: [
                    "fiveHour": adjustedQuota.fiveHour.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil",
                    "sevenDay": adjustedQuota.sevenDay.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil",
                    "resetCredits": String(adjustedQuota.availableResetCreditCount)
                ])

                await MainActor.run {
                    self.isRefreshing = false
                    self.lastSuccessfulRefreshCompletedAt = Date()
                    self.snapshot = adjustedQuota
                    self.historyStore?.record(adjustedQuota)
                }
                trace?.mark("mainActor.publish.end")
                trace?.end("ok")
            case .failure(let error):
                await MainActor.run {
                    self.isRefreshing = false
                    var failed = self.snapshot
                    failed.status = "额度读取失败：\(error.localizedDescription)"
                    self.snapshot = failed
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
        }
    }
}
