import Foundation

@MainActor
protocol AccountQuotaTimerToken: AnyObject {
    func invalidate()
}

@MainActor
protocol AccountQuotaTimerScheduling {
    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AccountQuotaTimerToken
}

@MainActor
private struct DefaultAccountQuotaTimerScheduler: AccountQuotaTimerScheduling {
    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AccountQuotaTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
        return FoundationAccountQuotaTimerToken(timer: timer)
    }
}

@MainActor
private final class FoundationAccountQuotaTimerToken: AccountQuotaTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

@MainActor
final class AccountQuotaStore: ObservableObject {
    @Published private(set) var snapshot = AccountQuotaSnapshot.empty

    private var timer: (any AccountQuotaTimerToken)?
    private weak var historyStore: QuotaHistoryStore?
    private var isRefreshing = false
    private var lastSuccessfulRefreshCompletedAt: Date?
    private(set) var automaticRefreshInterval: TimeInterval
    private let quotaReader: any QuotaReading
    private let timerScheduler: any AccountQuotaTimerScheduling
    private let userDefaults: UserDefaults
    nonisolated(unsafe) private var cadenceObserver: NSObjectProtocol?
    private var currentDataSource: CodexDataSource?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var activeRefreshSourceID: String?
    private var snapshotSourceID: String?

    var currentDataSourceIdentity: String? {
        currentDataSource?.stableIdentityKey
    }

    var currentDataSourcePath: String? {
        currentDataSource?.codexHome.standardizedFileURL.path
    }

    init(
        quotaReader: any QuotaReading = LiveAccountQuotaReader(),
        automaticRefreshInterval: TimeInterval? = nil,
        timerScheduler: any AccountQuotaTimerScheduling = DefaultAccountQuotaTimerScheduler(),
        userDefaults: UserDefaults = .standard,
        observesUserDefaults: Bool = true
    ) {
        self.quotaReader = quotaReader
        self.timerScheduler = timerScheduler
        self.userDefaults = userDefaults
        self.automaticRefreshInterval = automaticRefreshInterval
            ?? AccountQuotaRefreshCadence.storedValue(in: userDefaults).seconds
        if observesUserDefaults {
            cadenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: userDefaults,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let cadence = AccountQuotaRefreshCadence.storedValue(in: self.userDefaults)
                    self.setAutomaticRefreshInterval(cadence.seconds)
                }
            }
        }
    }

    deinit {
        if let cadenceObserver {
            NotificationCenter.default.removeObserver(cadenceObserver)
        }
    }

    func setDataSource(_ dataSource: CodexDataSource?) {
        let oldSourceID = quotaSourceID(for: currentDataSource)
        let newSourceID = quotaSourceID(for: dataSource)
        currentDataSource = dataSource
        guard oldSourceID != newSourceID else { return }

        lastSuccessfulRefreshCompletedAt = nil
        refreshTask?.cancel()
        refreshGeneration += 1
        activeRefreshSourceID = nil
        isRefreshing = false
        snapshot = .empty
        snapshotSourceID = nil
    }

    func setHistoryStore(_ historyStore: QuotaHistoryStore) {
        self.historyStore = historyStore
    }

    func start(dataSource: CodexDataSource? = nil) {
        guard timer == nil else { return }
        setDataSource(dataSource)
        refresh(force: true)
        installAutomaticRefreshTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setAutomaticRefreshInterval(_ interval: TimeInterval) {
        guard automaticRefreshInterval != interval else { return }
        automaticRefreshInterval = interval
        guard timer != nil else { return }
        installAutomaticRefreshTimer()
    }

    func refresh(force: Bool = true) {
        let effectiveDataSource = currentDataSource
        let sourceID = quotaSourceID(for: effectiveDataSource)
        let recentSuccessAge = lastSuccessfulRefreshCompletedAt.map { Date().timeIntervalSince($0) }
        let trace = RefreshPerformanceProbe.begin("quotaStore.refresh", metadata: [
            "alreadyRefreshing": isRefreshing ? "1" : "0",
            "available": snapshot.isAvailable ? "1" : "0",
            "force": force ? "1" : "0",
            "source": effectiveDataSource?.displayPath ?? "default",
            "recentSuccessAge": recentSuccessAge.map { String(format: "%.2f", $0) } ?? "nil"
        ])
        if isRefreshing, sourceID == activeRefreshSourceID {
            trace?.end("skipped-refresh-in-flight")
            return
        }
        if isRefreshing {
            refreshTask?.cancel()
            refreshGeneration += 1
            isRefreshing = false
            trace?.mark("cancelled-stale-refresh")
        }
        if !force,
           AccountQuotaAutomaticRefreshPolicy.shouldSkipAutomaticRefresh(
                snapshotIsAvailable: snapshot.isAvailable,
                recentSuccessAge: recentSuccessAge,
                automaticRefreshInterval: automaticRefreshInterval
           ) {
            trace?.end("skipped-recent-success", metadata: [
                "cooldown": String(format: "%.2f", AccountQuotaAutomaticRefreshPolicy.successCooldown(for: automaticRefreshInterval))
            ])
            return
        }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        activeRefreshSourceID = sourceID
        var refreshing = snapshotSourceID == sourceID ? snapshot : .empty
        refreshing.status = snapshot.isAvailable ? "正在更新额度" : "正在读取额度"
        snapshot = refreshing

        let reader = quotaReader
        refreshTask = Task.detached(priority: .utility) {
            trace?.mark("reader.begin")
            let result = await reader.readQuota(dataSource: effectiveDataSource)
            trace?.mark("reader.end")
            guard !Task.isCancelled else {
                trace?.end("cancelled")
                return
            }
            guard await MainActor.run(body: { self.isCurrentRefresh(generation: generation, sourceID: sourceID) }) else {
                trace?.end("stale-after-reader")
                return
            }
            switch result {
            case .success(let quota):
                trace?.mark("mainActor.previousSnapshot.begin")
                let previousSnapshot = await MainActor.run {
                    self.snapshotSourceID == sourceID ? self.snapshot : .empty
                }
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
                    guard self.isCurrentRefresh(generation: generation, sourceID: sourceID) else { return }
                    self.isRefreshing = false
                    self.activeRefreshSourceID = nil
                    self.lastSuccessfulRefreshCompletedAt = Date()
                    self.snapshot = adjustedQuota
                    self.snapshotSourceID = sourceID
                    self.historyStore?.record(adjustedQuota)
                }
                trace?.mark("mainActor.publish.end")
                trace?.end("ok")
            case .failure(let error):
                await MainActor.run {
                    guard self.isCurrentRefresh(generation: generation, sourceID: sourceID) else { return }
                    self.isRefreshing = false
                    self.activeRefreshSourceID = nil
                    let retainsSameSourceSnapshot = self.snapshotSourceID == sourceID
                        && self.snapshot.isAvailable
                    var failed = retainsSameSourceSnapshot ? self.snapshot : .empty
                    let occurredAt = Date()
                    let diagnostic = AccountQuotaDiagnostic.classify(
                        source: .accountQuota,
                        error: error,
                        occurredAt: occurredAt
                    )
                    var diagnostics = [diagnostic]
                    if retainsSameSourceSnapshot {
                        diagnostics.append(
                            .staleCachedData(
                                source: .accountQuota,
                                rawCause: diagnostic.rawCause,
                                occurredAt: occurredAt
                            )
                        )
                    }
                    failed.diagnostics = diagnostics
                    failed.status = "额度读取失败：\(diagnostic.message)"
                    self.snapshot = failed
                    if !retainsSameSourceSnapshot {
                        self.snapshotSourceID = nil
                    }
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
        }
    }

    private func isCurrentRefresh(generation: Int, sourceID: String) -> Bool {
        refreshGeneration == generation && activeRefreshSourceID == sourceID
    }

    private func installAutomaticRefreshTimer() {
        timer?.invalidate()
        timer = timerScheduler.scheduleRepeatingTimer(interval: automaticRefreshInterval) { [weak self] in
            self?.refresh(force: false)
        }
    }

    private func quotaSourceID(for dataSource: CodexDataSource?) -> String {
        dataSource?.stableIdentityKey ?? "automatic"
    }
}
