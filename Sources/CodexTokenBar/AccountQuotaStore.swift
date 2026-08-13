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

protocol AccountQuotaRetryScheduling: Sendable {
    func wait(for delay: TimeInterval) async throws
}

private struct DefaultAccountQuotaRetryScheduler: AccountQuotaRetryScheduling {
    func wait(for delay: TimeInterval) async throws {
        let seconds = min(max(delay, 0.1), 60)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
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
    static let maximumAutomaticRefreshInterval: TimeInterval = 60

    @Published private(set) var snapshot = AccountQuotaSnapshot.empty

    private var timer: (any AccountQuotaTimerToken)?
    private weak var historyStore: QuotaHistoryStore?
    private var isStarted = false

    private var isRefreshing = false
    private var isResetCreditRefreshing = false
    private var lastSuccessfulRefreshCompletedAt: Date?
    private(set) var automaticRefreshInterval: TimeInterval

    private let quotaReader: any QuotaReading
    private let resetCreditReader: (any AccountQuotaResetCreditReading)?
    private let timerScheduler: any AccountQuotaTimerScheduling
    private let retryScheduler: any AccountQuotaRetryScheduling
    private let userDefaults: UserDefaults
    nonisolated(unsafe) private var cadenceObserver: NSObjectProtocol?

    private var currentDataSource: CodexDataSource?
    private var refreshTask: Task<Void, Never>?
    private var resetCreditTask: Task<Void, Never>?
    private var quotaRetryTask: Task<Void, Never>?
    private var resetCreditRetryTask: Task<Void, Never>?
    private var quotaRetryBackoff = PersistentRefreshBackoff()
    private var resetCreditRetryBackoff = PersistentRefreshBackoff()

    private var refreshGeneration = 0
    private var resetCreditGeneration = 0
    private(set) var sourceIdentityGeneration = 0
    private(set) var sourceBindingGeneration = 0
    private var activeRefreshSourceID: String?
    private var activeResetCreditSourceID: String?
    private var snapshotSourceID: String?
    private var resetCreditSnapshotSourceID: String?
    private var quotaStatusBeforeRefresh: String?
    private var resetCreditStatusBeforeRefresh: String?

    var currentDataSourceIdentity: String? {
        currentDataSource?.stableIdentityKey
    }

    var currentDataSourcePath: String? {
        currentDataSource?.codexHome.standardizedFileURL.path
    }

    init(
        quotaReader: any QuotaReading = LiveAccountQuotaReader(),
        resetCreditReader: (any AccountQuotaResetCreditReading)? = nil,
        automaticRefreshInterval: TimeInterval? = nil,
        timerScheduler: any AccountQuotaTimerScheduling = DefaultAccountQuotaTimerScheduler(),
        retryScheduler: any AccountQuotaRetryScheduling = DefaultAccountQuotaRetryScheduler(),
        userDefaults: UserDefaults = .standard,
        observesUserDefaults: Bool = true
    ) {
        self.quotaReader = quotaReader
        self.resetCreditReader = resetCreditReader
        self.timerScheduler = timerScheduler
        self.retryScheduler = retryScheduler
        self.userDefaults = userDefaults
        self.automaticRefreshInterval = Self.normalizedAutomaticRefreshInterval(
            automaticRefreshInterval ?? AccountQuotaRefreshCadence.storedValue(in: userDefaults).seconds
        )
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

    @discardableResult
    func setDataSource(_ dataSource: CodexDataSource?) -> Bool {
        let oldSourceID = quotaSourceID(for: currentDataSource)
        let newSourceID = quotaSourceID(for: dataSource)
        let oldPath = currentDataSource?.codexHome.standardizedFileURL.path
        let newPath = dataSource?.codexHome.standardizedFileURL.path
        let identityChanged = oldSourceID != newSourceID
        let bindingChanged = oldPath != newPath
        currentDataSource = dataSource
        guard identityChanged || bindingChanged else { return false }

        cancelQuotaRefresh(restoreStatus: true)
        cancelResetCreditRefresh(restoreStatus: true)
        cancelQuotaRetry(resetBackoff: true)
        cancelResetCreditRetry(resetBackoff: true)
        sourceBindingGeneration += 1
        guard identityChanged else { return true }

        historyStore?.clearIdentity()
        sourceIdentityGeneration += 1
        lastSuccessfulRefreshCompletedAt = nil
        snapshot = .empty
        snapshotSourceID = nil
        resetCreditSnapshotSourceID = nil
        return true
    }

    func setHistoryStore(_ historyStore: QuotaHistoryStore) {
        self.historyStore = historyStore
    }

    func start(dataSource: CodexDataSource? = nil) {
        guard !isStarted else { return }
        setDataSource(dataSource)
        isStarted = true
        installAutomaticRefreshTimer()
        refresh(force: true)
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        cancelQuotaRefresh(restoreStatus: true)
        cancelResetCreditRefresh(restoreStatus: true)
        cancelQuotaRetry(resetBackoff: true)
        cancelResetCreditRetry(resetBackoff: true)
    }

    func setAutomaticRefreshInterval(_ interval: TimeInterval) {
        let normalized = Self.normalizedAutomaticRefreshInterval(interval)
        guard automaticRefreshInterval != normalized else { return }
        automaticRefreshInterval = normalized
        guard isStarted else { return }
        installAutomaticRefreshTimer()
    }

    func refresh(force: Bool = true) {
        refreshQuota(force: force)
        refreshResetCredits()
    }

    private func refreshQuota(force: Bool) {
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
            cancelQuotaRefresh(restoreStatus: true)
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

        cancelQuotaRetry(resetBackoff: false)
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let bindingGeneration = sourceBindingGeneration
        activeRefreshSourceID = sourceID
        quotaStatusBeforeRefresh = snapshot.status
        snapshot.status = snapshotSourceID == sourceID && snapshot.isAvailable
            ? "正在更新额度"
            : "正在读取额度"

        let reader = quotaReader
        refreshTask = Task.detached(priority: .utility) {
            trace?.mark("reader.begin")
            let result = await reader.readQuota(dataSource: effectiveDataSource)
            trace?.mark("reader.end")
            guard !Task.isCancelled else {
                trace?.end("cancelled")
                return
            }
            guard await MainActor.run(body: {
                self.isCurrentQuotaRefresh(
                    generation: generation,
                    bindingGeneration: bindingGeneration,
                    sourceID: sourceID
                )
            }) else {
                trace?.end("stale-after-reader")
                return
            }

            switch result {
            case .success(let quota):
                let previousSnapshot = await MainActor.run {
                    self.snapshotSourceID == sourceID ? self.snapshot : .empty
                }
                let historyStore = await MainActor.run { self.historyStore }
                let memoryAdjustedQuota = QuotaMonotonicNormalizer.normalizedSnapshot(quota, after: previousSnapshot)
                let adjustedQuota = await historyStore?.normalizedForDisplay(memoryAdjustedQuota) ?? memoryAdjustedQuota

                await MainActor.run {
                    guard self.isCurrentQuotaRefresh(
                        generation: generation,
                        bindingGeneration: bindingGeneration,
                        sourceID: sourceID
                    ) else { return }
                    let current = self.snapshot
                    var published = self.mergingQuota(adjustedQuota, withResetStateFrom: current)
                    let carriesEmbeddedReset = self.hasResetCreditPayload(adjustedQuota)
                    if carriesEmbeddedReset {
                        self.cancelResetCreditRefresh(restoreStatus: false)
                        self.cancelResetCreditRetry(resetBackoff: true)
                        self.resetCreditSnapshotSourceID = sourceID
                    }
                    self.isRefreshing = false
                    self.activeRefreshSourceID = nil
                    self.quotaStatusBeforeRefresh = nil
                    self.lastSuccessfulRefreshCompletedAt = Date()
                    self.cancelQuotaRetry(resetBackoff: true)
                    published.status = adjustedQuota.status
                    self.snapshot = published
                    self.snapshotSourceID = sourceID
                    self.historyStore?.record(published)
                }
                trace?.end("ok")

            case .failure(let error):
                await MainActor.run {
                    guard self.isCurrentQuotaRefresh(
                        generation: generation,
                        bindingGeneration: bindingGeneration,
                        sourceID: sourceID
                    ) else { return }
                    self.isRefreshing = false
                    self.activeRefreshSourceID = nil
                    self.quotaStatusBeforeRefresh = nil
                    let retainsSameSourceQuota = self.snapshotSourceID == sourceID
                        && self.snapshot.isAvailable
                    let retainsSameSourceReset = self.resetCreditSnapshotSourceID == sourceID
                    var failed = (retainsSameSourceQuota || retainsSameSourceReset) ? self.snapshot : .empty
                    let occurredAt = Date()
                    let diagnostic = AccountQuotaDiagnostic.classify(
                        source: .accountQuota,
                        error: error,
                        occurredAt: occurredAt
                    )
                    var quotaDiagnostics = [diagnostic]
                    if retainsSameSourceQuota {
                        quotaDiagnostics.append(
                            .staleCachedData(
                                source: .accountQuota,
                                rawCause: diagnostic.rawCause,
                                occurredAt: occurredAt
                            )
                        )
                    }
                    failed.diagnostics = quotaDiagnostics
                        + failed.diagnostics.filter { $0.source == .resetCredit }
                    failed.status = "额度读取失败：\(diagnostic.message)"
                    self.snapshot = failed
                    if !retainsSameSourceQuota {
                        self.snapshotSourceID = nil
                    }
                    self.scheduleQuotaRetry(sourceID: sourceID, bindingGeneration: bindingGeneration)
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
        }
    }

    private func refreshResetCredits() {
        guard let resetCreditReader else { return }
        let effectiveDataSource = currentDataSource
        let sourceID = quotaSourceID(for: effectiveDataSource)
        if isResetCreditRefreshing, sourceID == activeResetCreditSourceID {
            return
        }
        if isResetCreditRefreshing {
            cancelResetCreditRefresh(restoreStatus: true)
        }

        cancelResetCreditRetry(resetBackoff: false)
        isResetCreditRefreshing = true
        resetCreditGeneration += 1
        let generation = resetCreditGeneration
        let bindingGeneration = sourceBindingGeneration
        activeResetCreditSourceID = sourceID
        resetCreditStatusBeforeRefresh = snapshot.resetCreditStatus
        snapshot.resetCreditStatus = resetCreditSnapshotSourceID == sourceID
            && (snapshot.resetCreditsAvailableCount != nil || !snapshot.resetCredits.isEmpty)
            ? "正在更新重置卡"
            : "正在读取重置卡"

        resetCreditTask = Task.detached(priority: .utility) {
            let result = await resetCreditReader.readResetCredits(dataSource: effectiveDataSource)
            guard !Task.isCancelled else { return }
            guard await MainActor.run(body: {
                self.isCurrentResetCreditRefresh(
                    generation: generation,
                    bindingGeneration: bindingGeneration,
                    sourceID: sourceID
                )
            }) else { return }

            await MainActor.run {
                guard self.isCurrentResetCreditRefresh(
                    generation: generation,
                    bindingGeneration: bindingGeneration,
                    sourceID: sourceID
                ) else { return }
                self.isResetCreditRefreshing = false
                self.activeResetCreditSourceID = nil
                self.resetCreditStatusBeforeRefresh = nil
                switch result {
                case .success(let reset):
                    self.snapshot.resetCreditsAvailableCount = reset.availableCount
                    self.snapshot.resetCredits = reset.credits
                    self.snapshot.resetCreditStatus = reset.status
                    self.snapshot.resetCreditUpdatedAt = reset.updatedAt
                    self.snapshot.diagnostics.removeAll { $0.source == .resetCredit }
                    self.resetCreditSnapshotSourceID = sourceID
                    self.cancelResetCreditRetry(resetBackoff: true)

                case .failure(let diagnostic):
                    let retainsSameSourceReset = self.resetCreditSnapshotSourceID == sourceID
                        && (self.snapshot.resetCreditsAvailableCount != nil || !self.snapshot.resetCredits.isEmpty)
                    var resetDiagnostics = [diagnostic]
                    if retainsSameSourceReset {
                        resetDiagnostics.append(
                            .staleCachedData(
                                source: .resetCredit,
                                rawCause: diagnostic.rawCause,
                                occurredAt: Date()
                            )
                        )
                    }
                    self.snapshot.diagnostics = self.snapshot.diagnostics.filter { $0.source != .resetCredit }
                        + resetDiagnostics
                    self.snapshot.resetCreditStatus = "重置卡读取失败：\(diagnostic.message)"
                    if !retainsSameSourceReset {
                        self.resetCreditSnapshotSourceID = nil
                    }
                    self.scheduleResetCreditRetry(sourceID: sourceID, bindingGeneration: bindingGeneration)
                }
            }
        }
    }

    private func mergingQuota(
        _ quota: AccountQuotaSnapshot,
        withResetStateFrom current: AccountQuotaSnapshot
    ) -> AccountQuotaSnapshot {
        let carriesEmbeddedReset = hasResetCreditPayload(quota)
        var merged = quota
        let quotaDiagnostics = quota.diagnostics.filter { $0.source != .resetCredit }
        let incomingResetDiagnostics = quota.diagnostics.filter { $0.source == .resetCredit }
        if carriesEmbeddedReset {
            merged.diagnostics = quotaDiagnostics
                + incomingResetDiagnostics
            return merged
        }
        merged.resetCreditsAvailableCount = current.resetCreditsAvailableCount
        merged.resetCredits = current.resetCredits
        merged.resetCreditStatus = current.resetCreditStatus
        merged.resetCreditUpdatedAt = current.resetCreditUpdatedAt
        merged.diagnostics = quotaDiagnostics
            + (incomingResetDiagnostics.isEmpty
                ? current.diagnostics.filter { $0.source == .resetCredit }
                : incomingResetDiagnostics)
        return merged
    }

    private func hasResetCreditPayload(_ candidate: AccountQuotaSnapshot) -> Bool {
        candidate.resetCreditsAvailableCount != nil
            || !candidate.resetCredits.isEmpty
            || candidate.resetCreditUpdatedAt != nil
    }

    private func scheduleQuotaRetry(sourceID: String, bindingGeneration: Int) {
        guard isStarted else { return }
        let delay = quotaRetryBackoff.recordFailure(maximumDelay: Self.maximumAutomaticRefreshInterval)
        let scheduler = retryScheduler
        quotaRetryTask?.cancel()
        quotaRetryTask = Task { @MainActor [weak self] in
            do {
                try await scheduler.wait(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  self.isStarted,
                  self.sourceBindingGeneration == bindingGeneration,
                  self.quotaSourceID(for: self.currentDataSource) == sourceID else { return }
            self.quotaRetryTask = nil
            self.refreshQuota(force: true)
        }
    }

    private func scheduleResetCreditRetry(sourceID: String, bindingGeneration: Int) {
        guard isStarted else { return }
        let delay = resetCreditRetryBackoff.recordFailure(maximumDelay: Self.maximumAutomaticRefreshInterval)
        let scheduler = retryScheduler
        resetCreditRetryTask?.cancel()
        resetCreditRetryTask = Task { @MainActor [weak self] in
            do {
                try await scheduler.wait(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  self.isStarted,
                  self.sourceBindingGeneration == bindingGeneration,
                  self.quotaSourceID(for: self.currentDataSource) == sourceID else { return }
            self.resetCreditRetryTask = nil
            self.refreshResetCredits()
        }
    }

    private func cancelQuotaRefresh(restoreStatus: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        activeRefreshSourceID = nil
        isRefreshing = false
        if restoreStatus, let quotaStatusBeforeRefresh {
            snapshot.status = quotaStatusBeforeRefresh
        }
        quotaStatusBeforeRefresh = nil
    }

    private func cancelResetCreditRefresh(restoreStatus: Bool) {
        resetCreditTask?.cancel()
        resetCreditTask = nil
        resetCreditGeneration += 1
        activeResetCreditSourceID = nil
        isResetCreditRefreshing = false
        if restoreStatus, let resetCreditStatusBeforeRefresh {
            snapshot.resetCreditStatus = resetCreditStatusBeforeRefresh
        }
        resetCreditStatusBeforeRefresh = nil
    }

    private func cancelQuotaRetry(resetBackoff: Bool) {
        quotaRetryTask?.cancel()
        quotaRetryTask = nil
        if resetBackoff {
            quotaRetryBackoff.recordSuccess()
        }
    }

    private func cancelResetCreditRetry(resetBackoff: Bool) {
        resetCreditRetryTask?.cancel()
        resetCreditRetryTask = nil
        if resetBackoff {
            resetCreditRetryBackoff.recordSuccess()
        }
    }

    private func isCurrentQuotaRefresh(
        generation: Int,
        bindingGeneration: Int,
        sourceID: String
    ) -> Bool {
        refreshGeneration == generation
            && sourceBindingGeneration == bindingGeneration
            && activeRefreshSourceID == sourceID
    }

    private func isCurrentResetCreditRefresh(
        generation: Int,
        bindingGeneration: Int,
        sourceID: String
    ) -> Bool {
        resetCreditGeneration == generation
            && sourceBindingGeneration == bindingGeneration
            && activeResetCreditSourceID == sourceID
    }

    private func installAutomaticRefreshTimer() {
        timer?.invalidate()
        timer = timerScheduler.scheduleRepeatingTimer(interval: automaticRefreshInterval) { [weak self] in
            self?.refresh(force: false)
        }
    }

    private static func normalizedAutomaticRefreshInterval(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, AccountQuotaRefreshCadence.thirtySeconds.seconds), maximumAutomaticRefreshInterval)
    }

    private func quotaSourceID(for dataSource: CodexDataSource?) -> String {
        dataSource?.stableIdentityKey ?? "automatic"
    }
}
