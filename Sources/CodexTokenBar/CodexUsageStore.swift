import AppKit
import Combine
import CryptoKit
import Foundation

enum PreciseTimeSeriesContinuityLossReason: String, Codable, Equatable, Sendable {
    case observationGap
    case observerTakeover
    case storageRecovery
}

struct PreciseTimeSeriesContinuityLossRecord: Codable, Equatable, Sendable {
    let id: UUID
    let detectedAt: Date
    let reason: PreciseTimeSeriesContinuityLossReason?

    init(
        id: UUID,
        detectedAt: Date,
        reason: PreciseTimeSeriesContinuityLossReason? = nil
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.reason = reason
    }
}

enum SharedAccountUsageSafetyRecoveryState: Equatable, Sendable {
    case idle
    case required
    case rebuilding
    case awaitingFreshBaseline
    case failed
}

private final class SharedAccountContinuityObserverToken: @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let token: NSObjectProtocol

    init(center: DistributedNotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot = .empty
    private(set) var todayModelBreakdowns: [ModelTokenBreakdown] = []
    /// The last successful exact model snapshot's local day. A fast/compact
    /// refresh can temporarily lack attribution rows; retaining this marker
    /// lets us keep that snapshot only within the same day and source.
    private var todayModelBreakdownsDay: Date?
    @Published private(set) var status: String = "正在加载本地 Codex 用量..."
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDetailHydrating = false
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isPreparingUsageCache = false
    @Published private(set) var preciseIndexProgress: PreciseIndexProgress = .idle
    /// Exact numeric time-series coverage; intentionally independent of
    /// attribution-event and excerpt/detail readiness.
    @Published private(set) var preciseTimeSeriesFresh = false
    /// A compact summary updates only totals/today's projection and leaves the
    /// last exact time-series coverage in place. Attribution may use that
    /// coverage only after DashboardView proves the current quota boundary is
    /// still covered; all real/full refreshes clear this marker.
    @Published private(set) var isCompactSummaryPending = false
    @Published private(set) var preciseTimeSeriesContinuityLostAt: Date? = nil
    @Published private(set) var preciseTimeSeriesContinuityLossID: UUID? = nil
    @Published private(set) var preciseTimeSeriesContinuityLossReason:
        PreciseTimeSeriesContinuityLossReason? = nil
    @Published private(set) var preciseContinuityPersistenceHealthy = true
    @Published private(set) var preciseObservationSessionID = UUID()
    @Published private(set) var preciseSessionMutationMonitoringHealthy = false
    @Published private(set) var sharedAccountSafetyRecoveryState:
        SharedAccountUsageSafetyRecoveryState = .idle
    @Published private(set) var dataSourceLabel: String = "查找 Codex 目录..."
    @Published private(set) var dataSourceOrigin: String = "自动"
    @Published private(set) var dataSourceIdentity: String?
    @Published private(set) var dataSourceBindingKey = "none"
    @Published var selectedMode: ActivityMode = .daily

    private let resolver: CodexDataSourceResolving
    private let snapshotLoader: DashboardSnapshotLoading
    private var dataSource: CodexDataSource?
    private var timer: Timer?
    private var initialPreciseTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var transientDatabaseRecoveryTask: Task<Void, Never>?
    private let transientDatabaseRecoveryDelay: TimeInterval
    private var refreshGeneration = 0
    private(set) var sourceIdentityGeneration = 0
    private(set) var sourceBindingGeneration = 0
    private var activeRefreshSourceID: String?
    private var snapshotSourceID: String?
    private var refreshInterval: TimeInterval = 300
    private var didFinishInitialLoad = false
    private var didRunPreciseScan = false
    private var backgroundActivityEnabled = true
    private var onlyCompactSurfaceVisible = false
    private var activeRefreshCompactOnly = false
    private var pendingFullRefresh = false
    private var attributionSafetyAckTask: Task<Void, Never>?
    private var pendingAttributionSafetyAckKey: String?
    private let continuityDefaults: UserDefaults
    private let continuityStorageKey: String
    private let legacyContinuityStorageKey: String?
    private let continuitySafetyDatabase: SharedAccountUsageSafetyDatabase?
    private var continuityObserver: SharedAccountContinuityObserverToken?
    private let sessionMutationMonitor = CodexSessionMutationMonitor()
    private var sessionMutationMonitoringActive = false
    private static let maxTransientDatabaseRecoveryAttempts = 5

    nonisolated static let preciseContinuityStorageKey = "preciseTimeSeriesContinuityLossesV02"
    nonisolated static let legacyPreciseContinuityStorageKey = "preciseTimeSeriesContinuityLossesV01"

    nonisolated static var sharedAccountSafetyMigrationStorageKeys: [String] {
        UserDefaultsSharedAccountUsageHighWatermarkStore.allMigrationStorageKeys
            + UserDefaultsSharedAccountUsageSegmentStore.allMigrationStorageKeys
            + [preciseContinuityStorageKey, legacyPreciseContinuityStorageKey]
    }

    var currentDataSource: CodexDataSource? {
        dataSource
    }

    var isUsageRefreshOrDetailHydrationActive: Bool {
        isRefreshing || isDetailHydrating
    }

    init(
        resolver: CodexDataSourceResolving = CodexDataSourceResolver(),
        snapshotLoader: DashboardSnapshotLoading = CodexDashboardSnapshotLoader(),
        autoStart: Bool = true,
        continuityDefaults: UserDefaults = .standard,
        continuityStorageKey: String = preciseContinuityStorageKey,
        legacyContinuityStorageKey: String? = legacyPreciseContinuityStorageKey,
        continuitySafetyDatabase: SharedAccountUsageSafetyDatabase? = nil,
        transientDatabaseRecoveryDelay: TimeInterval = 2.0
    ) {
        self.resolver = resolver
        self.snapshotLoader = snapshotLoader
        self.continuityDefaults = continuityDefaults
        self.continuityStorageKey = continuityStorageKey
        self.legacyContinuityStorageKey = legacyContinuityStorageKey
        self.continuitySafetyDatabase = continuitySafetyDatabase
        self.transientDatabaseRecoveryDelay = max(0.05, transientDatabaseRecoveryDelay)
        dataSource = resolver.resolve()
        dataSourceIdentity = dataSource?.stableIdentityKey
        dataSourceBindingKey = Self.bindingKey(for: dataSource)
        if continuitySafetyDatabase != nil {
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(
                forName: SharedAccountUsageSafetyDatabase.didChangeNotification,
                object: SharedAccountUsageSafetyDatabase.RecordKind.preciseContinuity.rawValue,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reloadPreciseTimeSeriesContinuityLoss()
                }
            }
            continuityObserver = SharedAccountContinuityObserverToken(
                center: center,
                token: token
            )
        }
        loadContinuityLoss(for: dataSource)
        if continuitySafetyDatabase?.recoveryRequired == true {
            sharedAccountSafetyRecoveryState = .required
        }
        updateDataSourceLabels()
        if autoStart {
            sessionMutationMonitoringActive = true
            configureSessionMutationMonitor()
            refreshInitialSnapshot()
            scheduleInitialPreciseRefresh()
            scheduleTimer()
        }
    }

    func refresh() {
        // An open continuity loss gets a full recovery attempt even when only
        // compact surfaces are visible. Transient SQLite failures additionally
        // start one bounded exponential recovery episode; permanent/exhausted
        // errors remain on the regular timer/manual cadence.
        refresh(
            includePreciseScan: true,
            forceFullTimeSeries: preciseTimeSeriesContinuityLossID != nil
        )
    }

    /// Attribution compares local usage with a point-in-time quota snapshot.
    /// This path bypasses the compact-summary optimization so the time series
    /// can explicitly catch up to a newer quota observation.
    func refreshPreciseTimeSeriesForAttribution() {
        refresh(includePreciseScan: true, forceFullTimeSeries: true)
    }

    /// Refresh the process-local view from the crash-durable continuity ledger.
    /// Shared-account attribution calls this while holding its cross-process
    /// safety lock so a gap recorded by another Token Bar process cannot remain
    /// an indefinitely stale `nil` in this process.
    func reloadPreciseTimeSeriesContinuityLoss() {
        loadContinuityLoss(for: dataSource)
    }

    /// User-invoked recovery for a damaged shared-account safety ledger. The
    /// database performs quarantine + atomic replacement; this store then
    /// rotates every observation boundary and starts a fresh precise scan. The
    /// caller should also request a fresh quota snapshot.
    @discardableResult
    func rebuildSharedAccountSafetyBaseline() async -> Bool {
        guard let continuitySafetyDatabase,
              let dataSource,
              continuitySafetyDatabase.recoveryRequired,
              sharedAccountSafetyRecoveryState != .rebuilding else {
            return false
        }
        sharedAccountSafetyRecoveryState = .rebuilding
        let loss = PreciseTimeSeriesContinuityLossRecord(
            id: UUID(),
            detectedAt: Date(),
            reason: .storageRecovery
        )
        guard let payload = try? JSONEncoder().encode([
            Self.continuityIdentifier(for: dataSource): loss,
        ]) else {
            sharedAccountSafetyRecoveryState = .failed
            return false
        }
        let defaults = continuityDefaults
        let keys = Set(
            Self.sharedAccountSafetyMigrationStorageKeys
                + [continuityStorageKey, legacyContinuityStorageKey]
                    .compactMap { $0 }
        ).sorted()
        // Yield once so SwiftUI can present the rebuilding state. The recovery
        // itself only renames the old SQLite family and builds a tiny empty
        // generation; keeping UserDefaults access on its owning actor avoids a
        // cross-actor preferences race.
        await Task.yield()
        let recovery = continuitySafetyDatabase.rebuildEmptySafetyBaseline(
            preciseContinuityPayload: payload,
            defaults: defaults,
            retiredUserDefaultsKeys: keys
        )
        guard recovery != nil,
              continuitySafetyDatabase.persistenceHealthy,
              continuitySafetyDatabase.isObserverOwner else {
            preciseContinuityPersistenceHealthy = false
            sharedAccountSafetyRecoveryState = .failed
            return false
        }

        preciseObservationSessionID = UUID()
        preciseTimeSeriesFresh = false
        isCompactSummaryPending = false
        loadContinuityLoss(for: dataSource)
        guard preciseContinuityPersistenceHealthy,
              preciseTimeSeriesContinuityLossID == loss.id else {
            sharedAccountSafetyRecoveryState = .failed
            return false
        }
        sharedAccountSafetyRecoveryState = .awaitingFreshBaseline
        sessionMutationMonitoringActive = backgroundActivityEnabled
        configureSessionMutationMonitor()
        restartWithForcedPreciseRefresh()
        return true
    }

    func acknowledgeAttributionSafetyAfterDurableCutover(
        provenanceEpoch: String,
        throughGeneration: Int64
    ) {
        guard let dataSource,
              snapshot.cacheUsage.attributionProvenanceEpoch == provenanceEpoch,
              snapshot.cacheUsage.attributionGeneration == throughGeneration,
              snapshot.cacheUsage.attributionUnsafeSinceGeneration != nil,
              !snapshot.cacheUsage.attributionCurrentScanUnsafeCauseDetected else {
            return
        }
        let sourceID = refreshSourceID(for: dataSource)
        let bindingKey = Self.bindingKey(for: dataSource)
        let key = "\(bindingKey)\u{1f}\(provenanceEpoch)\u{1f}\(throughGeneration)"
        guard pendingAttributionSafetyAckKey != key else { return }
        attributionSafetyAckTask?.cancel()
        pendingAttributionSafetyAckKey = key
        attributionSafetyAckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let acknowledged = (try? await self.snapshotLoader.acknowledgeAttributionSafety(
                dataSource: dataSource,
                provenanceEpoch: provenanceEpoch,
                throughGeneration: throughGeneration
            )) ?? false
            guard !Task.isCancelled,
                  self.pendingAttributionSafetyAckKey == key,
                  self.dataSourceBindingKey == bindingKey,
                  self.dataSource?.stableIdentityKey == sourceID else {
                return
            }
            self.pendingAttributionSafetyAckKey = nil
            self.attributionSafetyAckTask = nil
            if acknowledged {
                self.refreshPreciseTimeSeriesForAttribution()
            }
        }
    }

    // 决策口径：仅紧凑 surface（状态栏/悬浮窗）可见时，周期刷新走轻量
    // summary（索引增量同步 + 三条 SUM SQL），不重建时间序列/排行/摘录。
    func setOnlyCompactSurfaceVisible(_ visible: Bool) {
        guard onlyCompactSurfaceVisible != visible else { return }
        onlyCompactSurfaceVisible = visible
        // 仪表盘展开时立即全量刷新一次，补齐轻量期间未更新的时间序列/排行。
        if !visible, didRunPreciseScan, backgroundActivityEnabled {
            refresh()
        }
    }

    @discardableResult
    func setDataSource(_ nextDataSource: CodexDataSource?) -> Bool {
        let previousIdentity = dataSource?.stableIdentityKey
        let nextIdentity = nextDataSource?.stableIdentityKey
        let previousPath = dataSource?.codexHome.standardizedFileURL.path
        let nextPath = nextDataSource?.codexHome.standardizedFileURL.path
        let identityChanged = previousIdentity != nextIdentity
        let bindingChanged = previousPath != nextPath
        if identityChanged || bindingChanged {
            // Switching away from a Home creates an interval that this process
            // cannot observe for that Home. Rotate before binding the watcher
            // to the next root so returning A -> B -> A cannot reuse A's old
            // ready attribution segment across the unobserved interval.
            preciseObservationSessionID = UUID()
        }
        dataSource = nextDataSource
        dataSourceIdentity = nextIdentity
        dataSourceBindingKey = Self.bindingKey(for: nextDataSource)
        if identityChanged {
            loadContinuityLoss(for: nextDataSource)
        }
        updateDataSourceLabels()

        guard identityChanged || bindingChanged else { return false }

        if sessionMutationMonitoringActive {
            configureSessionMutationMonitor()
        }

        refreshTask?.cancel()
        refreshTask = nil
        transientDatabaseRecoveryTask?.cancel()
        transientDatabaseRecoveryTask = nil
        attributionSafetyAckTask?.cancel()
        attributionSafetyAckTask = nil
        pendingAttributionSafetyAckKey = nil
        refreshGeneration += 1
        sourceBindingGeneration += 1
        activeRefreshSourceID = nil
        activeRefreshCompactOnly = false
        pendingFullRefresh = false
        isRefreshing = false
        isDetailHydrating = false
        isPreparingUsageCache = false
        preciseTimeSeriesFresh = false
        isCompactSummaryPending = false
        todayModelBreakdownsDay = nil
        guard identityChanged else { return true }

        sourceIdentityGeneration += 1
        snapshot = .empty
        todayModelBreakdowns = []
        snapshotSourceID = nil
        didRunPreciseScan = false
        status = nextDataSource == nil
            ? "未找到本地 Codex 数据目录"
            : "正在读取新数据源..."
        return true
    }

    private static func bindingKey(for dataSource: CodexDataSource?) -> String {
        guard let dataSource else { return "none" }
        return "\(dataSource.stableIdentityKey)\u{0}\(dataSource.codexHome.standardizedFileURL.path)"
    }

    private func refreshInitialSnapshot() {
        refresh(includePreciseScan: false)
    }

    private func refresh(
        includePreciseScan: Bool,
        forceFullTimeSeries: Bool = false,
        transientRecoveryAttempt: Int? = nil
    ) {
        if transientRecoveryAttempt == nil {
            transientDatabaseRecoveryTask?.cancel()
            transientDatabaseRecoveryTask = nil
        }
        let observerTakeover = continuitySafetyDatabase?.attemptObserverTakeover() ?? false
        let effectiveIncludePreciseScan = (includePreciseScan || observerTakeover)
            && (continuitySafetyDatabase?.isObserverOwner ?? true)
        let effectiveForceFullTimeSeries = forceFullTimeSeries || observerTakeover
        let resolvedDataSource = resolver.resolve()
        let requestedSourceID = resolvedDataSource.map { refreshSourceID(for: $0) }
        let trace = RefreshPerformanceProbe.begin("usageStore.refresh", metadata: [
            "includePreciseScan": effectiveIncludePreciseScan ? "1" : "0",
            "forceFullTimeSeries": effectiveForceFullTimeSeries ? "1" : "0",
            "observerTakeover": observerTakeover ? "1" : "0",
            "alreadyRefreshing": isRefreshing ? "1" : "0",
            "source": resolvedDataSource?.displayPath ?? "nil"
        ])
        clearStaleTodayModelBreakdownsIfNeeded()
        let requestedBindingKey = Self.bindingKey(for: resolvedDataSource)
        if isRefreshing,
           requestedSourceID == activeRefreshSourceID,
           requestedBindingKey == dataSourceBindingKey,
           !observerTakeover {
            if sessionMutationMonitoringActive,
               backgroundActivityEnabled,
               (continuitySafetyDatabase?.isObserverOwner ?? true),
               !preciseSessionMutationMonitoringHealthy {
                configureSessionMutationMonitor()
            }
            if effectiveIncludePreciseScan,
               activeRefreshCompactOnly,
               (effectiveForceFullTimeSeries || !onlyCompactSurfaceVisible) {
                pendingFullRefresh = true
            }
            trace?.end("skipped-refresh-in-flight")
            return
        }
        if requestedBindingKey != dataSourceBindingKey {
            setDataSource(resolvedDataSource)
            trace?.mark("rebound-source")
        } else if isRefreshing {
            refreshTask?.cancel()
            refreshTask = nil
            transientDatabaseRecoveryTask?.cancel()
            transientDatabaseRecoveryTask = nil
            refreshGeneration += 1
            isRefreshing = false
            isDetailHydrating = false
            trace?.mark("cancelled-stale-refresh")
        } else if refreshTask != nil {
            // A numeric phase releases the visible refresh lifecycle before
            // its optional detail hydration finishes. A later dirty/manual
            // refresh owns the newer numeric generation and cancels only that
            // trailing detail task.
            refreshTask?.cancel()
            refreshTask = nil
            isDetailHydrating = false
            trace?.mark("cancelled-superseded-detail")
        }
        setDataSource(resolvedDataSource)

        guard let dataSource else {
            refreshTask?.cancel()
            refreshGeneration += 1
            activeRefreshSourceID = nil
            activeRefreshCompactOnly = false
            pendingFullRefresh = false
            isDetailHydrating = false
            isCompactSummaryPending = false
            snapshot = .empty
            todayModelBreakdowns = []
            todayModelBreakdownsDay = nil
            snapshotSourceID = nil
            preciseTimeSeriesFresh = false
            status = "未找到本地 Codex 数据目录"
            isInitialLoading = false
            isPreparingUsageCache = false
            didFinishInitialLoad = true
            trace?.end("no-data-source")
            return
        }

        if observerTakeover {
            prepareAfterObserverTakeover(for: dataSource)
        } else if sessionMutationMonitoringActive,
                  backgroundActivityEnabled,
                  (continuitySafetyDatabase?.isObserverOwner ?? true),
                  !preciseSessionMutationMonitoringHealthy {
            // FSEvents setup can fail transiently while a selected Home is
            // being created, remounted, or restored. Retry on the normal/manual
            // refresh cadence; do not require an app restart or rebuild the
            // unrelated safety database.
            configureSessionMutationMonitor()
        }

        let sourceID = refreshSourceID(for: dataSource)
        if let snapshotSourceID, snapshotSourceID != sourceID {
            snapshot = .empty
            todayModelBreakdowns = []
            todayModelBreakdownsDay = nil
            self.snapshotSourceID = nil
            preciseTimeSeriesFresh = false
            isCompactSummaryPending = false
        }
        let isFirstLoad = !didFinishInitialLoad
        let needsCacheInitialization = effectiveIncludePreciseScan && !UsageCacheLifecycle.isCurrentCachePrepared
        activeRefreshCompactOnly = effectiveIncludePreciseScan
            && !effectiveForceFullTimeSeries
            && !isFirstLoad
            && onlyCompactSurfaceVisible
            && snapshot.hasPreciseTokenUsage
            && snapshotSourceID == sourceID
        isRefreshing = true
        isDetailHydrating = false
        preciseIndexProgress = PreciseIndexProgress(
            phase: .preparing,
            message: needsCacheInitialization
                ? "正在计算索引规模，可能需要数分钟"
                : "正在准备精确统计",
            completed: 0,
            total: nil
        )
        // A pending marker belongs only to the last successful compact
        // summary. Any new refresh must establish its own freshness boundary.
        isCompactSummaryPending = false
        refreshGeneration += 1
        let generation = refreshGeneration
        let bindingGeneration = sourceBindingGeneration
        activeRefreshSourceID = sourceID
        isPreparingUsageCache = needsCacheInitialization
        if isFirstLoad {
            isInitialLoading = true
            status = needsCacheInitialization
                ? "正在建立本地统计缓存..."
                : "正在读取本地索引..."
        } else {
            status = needsCacheInitialization
                ? "正在建立本地统计缓存..."
                : "正在增量更新 token..."
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let source = dataSource
            var shouldScheduleTransientDatabaseRecovery = false
            var transientRecoveryIncludePreciseScan = true
            var transientRecoveryForceFullTimeSeries = true
            var sawNumericPrecisePhase = false
            do {
                trace?.mark("task.started", metadata: [
                    "source": source.displayPath,
                    "origin": source.originLabel
                ])
                if isFirstLoad || !effectiveIncludePreciseScan {
                    if effectiveIncludePreciseScan {
                        trace?.mark("fastSnapshot.begin")
                        if let quick = try? await self.snapshotLoader.loadFastSnapshotResult(
                            dataSource: source
                        ) {
                            guard self.isCurrentRefresh(
                                generation: generation,
                                bindingGeneration: bindingGeneration,
                                sourceID: sourceID
                            ) else {
                                trace?.end("stale-after-fastSnapshot")
                                return
                            }
                            self.publish(quick.snapshot, sourceID: sourceID)
                            self.applyFastSnapshotFreshness(quick)
                            self.status = self.fastSnapshotStatus(
                                quick,
                                origin: source.originLabel,
                                preciseFollowUp: needsCacheInitialization
                                    ? "正在初始化本地统计缓存..."
                                    : "正在增量更新 token..."
                            )
                            trace?.mark("fastSnapshot.end", metadata: [
                                "tokens": String(quick.snapshot.stats.totalTokens),
                                "threads": String(quick.snapshot.stats.totalThreads),
                                "freshness": String(describing: quick.freshness)
                            ])
                        }
                    } else {
                        trace?.mark("fastSnapshot.begin")
                        let quick = try await self.snapshotLoader.loadFastSnapshotResult(
                            dataSource: source
                        )
                        guard self.isCurrentRefresh(
                            generation: generation,
                            bindingGeneration: bindingGeneration,
                            sourceID: sourceID
                        ) else {
                            trace?.end("stale-after-fastSnapshot")
                            return
                        }
                        self.publish(quick.snapshot, sourceID: sourceID)
                        self.applyFastSnapshotFreshness(quick)
                        self.status = self.fastSnapshotStatus(
                            quick,
                            origin: source.originLabel,
                            preciseFollowUp: "准备扫描精确 token..."
                        )
                        trace?.mark("fastSnapshot.end", metadata: [
                            "tokens": String(quick.snapshot.stats.totalTokens),
                            "threads": String(quick.snapshot.stats.totalThreads),
                            "freshness": String(describing: quick.freshness)
                        ])
                    }
                }

                if effectiveIncludePreciseScan {
                    var compactSummaryApplied = false
                    if !isFirstLoad,
                       !effectiveForceFullTimeSeries,
                       self.onlyCompactSurfaceVisible,
                       self.snapshot.hasPreciseTokenUsage,
                       self.snapshotSourceID == sourceID {
                        trace?.mark("compactSummary.begin")
                        // 轻量路径失败只回退全量，不让它变成整轮刷新失败。
                        let summary = try? await self.snapshotLoader.loadCompactSummary(
                            dataSource: source
                        )
                        guard self.isCurrentRefresh(
                            generation: generation,
                            bindingGeneration: bindingGeneration,
                            sourceID: sourceID
                        ) else {
                            trace?.end("stale-after-compactSummary")
                            return
                        }
                        if let summary {
                            self.publish(
                                Self.applyingCompactSummary(summary, to: self.snapshot),
                                todayModelBreakdowns: summary.todayModelBreakdowns,
                                sourceID: sourceID
                            )
                            self.preciseTimeSeriesFresh = false
                            self.isCompactSummaryPending = true
                            self.didRunPreciseScan = true
                            self.status = "\(source.originLabel) · token_count · 更新于 \(DateFormatter.statusString(from: summary.generatedAt))"
                            trace?.mark("compactSummary.end", metadata: [
                                "tokens": String(summary.totalTokens)
                            ])
                            compactSummaryApplied = true
                        } else {
                            trace?.mark("compactSummary.unavailable")
                        }
                    }
                    if !compactSummaryApplied {
                        trace?.mark("preciseSnapshot.begin")
                        var sawFinalPrecisePhase = false
                        let precisePhases: AsyncThrowingStream<DashboardSnapshot, Error>
                        if let progressLoader = self.snapshotLoader as? any DashboardSnapshotProgressLoading {
                            precisePhases = progressLoader.loadSnapshotPhases(dataSource: source) { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.isCurrentRefresh(
                                              generation: generation,
                                              bindingGeneration: bindingGeneration,
                                              sourceID: sourceID
                                          ) else { return }
                                    self.preciseIndexProgress = progress
                                    if progress.isActive {
                                        self.status = progress.message
                                    }
                                }
                            }
                        } else {
                            precisePhases = self.snapshotLoader.loadSnapshotPhases(
                                dataSource: source
                            )
                        }
                        for try await loaded in precisePhases {
                            guard self.isCurrentRefresh(
                                generation: generation,
                                bindingGeneration: bindingGeneration,
                                sourceID: sourceID
                            ) else {
                                trace?.end("stale-after-preciseSnapshot")
                                return
                            }
                            if loaded.hasPreciseTokenUsage {
                                self.publish(loaded, sourceID: sourceID)
                                if loaded.cacheUsage.attributionEventsComplete {
                                    sawFinalPrecisePhase = true
                                    self.isDetailHydrating = false
                                    self.preciseTimeSeriesFresh =
                                        loaded.preciseTimeSeriesGeneratedAt != nil
                                    self.isCompactSummaryPending = false
                                    self.didRunPreciseScan = true
                                    UsageCacheLifecycle.markCurrentCachePrepared()
                                    self.status = "\(source.originLabel) · token_count · 更新于 \(DateFormatter.statusString(from: loaded.generatedAt))"
                                    self.preciseIndexProgress = PreciseIndexProgress(
                                        phase: .complete,
                                        message: "精确统计已更新",
                                        completed: 1,
                                        total: 1
                                    )
                                    trace?.mark("preciseSnapshot.finalPhase", metadata: [
                                        "tokens": String(loaded.stats.totalTokens),
                                        "calls": String(loaded.stats.totalCalls),
                                        "threads": String(loaded.stats.totalThreads)
                                    ])
                                } else {
                                    // The exact numeric phase is a successful,
                                    // durable refresh boundary. Detail/excerpt
                                    // hydration continues independently and
                                    // must not hold totals in a processing state.
                                    sawNumericPrecisePhase = true
                                    self.isDetailHydrating = true
                                    self.preciseTimeSeriesFresh =
                                        loaded.preciseTimeSeriesGeneratedAt != nil
                                    self.isCompactSummaryPending = false
                                    self.didRunPreciseScan = true
                                    UsageCacheLifecycle.markCurrentCachePrepared()
                                    self.status = "\(source.originLabel) · token_count · 数值更新于 \(DateFormatter.statusString(from: loaded.generatedAt)) · 正在补齐会话明细..."
                                    self.isRefreshing = false
                                    self.didFinishInitialLoad = true
                                    self.isInitialLoading = false
                                    self.isPreparingUsageCache = false
                                    self.preciseIndexProgress = .idle
                                    self.activeRefreshCompactOnly = false
                                    trace?.mark("preciseSnapshot.numericPhase", metadata: [
                                        "tokens": String(loaded.stats.totalTokens),
                                        "calls": String(loaded.stats.totalCalls)
                                    ])
                                }
                            } else {
                                self.isDetailHydrating = false
                                self.preciseTimeSeriesFresh = false
                                self.isCompactSummaryPending = false
                                self.markPreciseTimeSeriesContinuityLoss(for: source)
                                if !self.snapshot.hasPreciseTokenUsage {
                                    self.publish(loaded, sourceID: sourceID)
                                    self.status = self.metadataOnlyStatus(origin: source.originLabel)
                                } else {
                                    self.status = self.staleMetadataOnlyStatus(origin: source.originLabel)
                                }
                                trace?.mark("preciseSnapshot.metadataOnly", metadata: [
                                    "threads": String(loaded.stats.totalThreads)
                                ])
                            }
                        }
                        if !sawFinalPrecisePhase {
                            trace?.mark("preciseSnapshot.noFinalPhase")
                            if sawNumericPrecisePhase {
                                self.isDetailHydrating = false
                                self.status = "\(source.originLabel) · token_count · 数值已更新，会话明细待后续刷新"
                            }
                        }
                    }
                }
                trace?.end("ok")
            } catch {
                guard self.isCurrentRefresh(
                    generation: generation,
                    bindingGeneration: bindingGeneration,
                    sourceID: sourceID
                ) else {
                    trace?.end("stale-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                if sawNumericPrecisePhase {
                    // Numeric aggregation already committed atomically. A
                    // detail-only error is not an exact-total failure, does
                    // not open continuity recovery, and does not stale totals.
                    self.isDetailHydrating = false
                    self.isCompactSummaryPending = false
                    self.status = "\(source.originLabel) · token_count · 数值已更新，会话明细暂不可用"
                    shouldScheduleTransientDatabaseRecovery = false
                    trace?.end("detail-failed", metadata: [
                        "error": error.localizedDescription
                    ])
                } else {
                    self.isDetailHydrating = false
                    self.isCompactSummaryPending = false
                    self.preciseIndexProgress = PreciseIndexProgress(
                        phase: .failed,
                        message: "精确统计失败，保留上次可信数据",
                        completed: 0,
                        total: nil
                    )
                    let retainedTrustedSnapshot = self.snapshotSourceID == sourceID
                        && self.hasDisplayableSnapshot(self.snapshot)
                    if !retainedTrustedSnapshot {
                        self.snapshot = .empty
                        self.todayModelBreakdowns = []
                        self.todayModelBreakdownsDay = nil
                        self.snapshotSourceID = nil
                    }
                    self.preciseTimeSeriesFresh = false
                    if includePreciseScan,
                       (transientRecoveryAttempt == nil
                            || self.preciseTimeSeriesContinuityLossID == nil),
                       let currentSource = self.dataSource {
                        self.markPreciseTimeSeriesContinuityLoss(for: currentSource)
                    }
                    let isTransientReadFailure = SQLiteReadRecovery.isTransientReadFailure(error)
                    shouldScheduleTransientDatabaseRecovery = isTransientReadFailure
                        && (transientRecoveryAttempt ?? 0)
                            < Self.maxTransientDatabaseRecoveryAttempts
                    transientRecoveryIncludePreciseScan = includePreciseScan
                    transientRecoveryForceFullTimeSeries = forceFullTimeSeries
                    if shouldScheduleTransientDatabaseRecovery {
                        // state_5.sqlite is externally owned and may be
                        // checkpointing its WAL during login/startup. Keep the
                        // last trusted value, but do not expose that expected
                        // short race as a user-facing read failure.
                        self.status = retainedTrustedSnapshot
                            ? "正在等待本地索引就绪（保留上次可信数据）..."
                            : "正在等待本地索引就绪..."
                    } else {
                        self.status = retainedTrustedSnapshot
                            ? "读取失败（保留上次可信数据，当前显示已陈旧）：\(error.localizedDescription)"
                            : "读取失败：\(error.localizedDescription)"
                    }
                    trace?.end("failed", metadata: [
                        "error": error.localizedDescription,
                        "transient": isTransientReadFailure ? "1" : "0",
                        "recoveryScheduled": shouldScheduleTransientDatabaseRecovery ? "1" : "0"
                    ])
                }
            }
            if self.isCurrentRefresh(
                generation: generation,
                bindingGeneration: bindingGeneration,
                sourceID: sourceID
            ) {
                let shouldRunPendingFullRefresh = self.pendingFullRefresh
                    && !self.onlyCompactSurfaceVisible
                    && self.backgroundActivityEnabled
                self.pendingFullRefresh = false
                self.activeRefreshCompactOnly = false
                self.isRefreshing = false
                self.isDetailHydrating = false
                self.activeRefreshSourceID = nil
                self.didFinishInitialLoad = true
                self.isInitialLoading = false
                self.isPreparingUsageCache = false
                self.refreshTask = nil
                if shouldRunPendingFullRefresh {
                    self.refresh(
                        includePreciseScan: true,
                        forceFullTimeSeries: true,
                        transientRecoveryAttempt: transientRecoveryAttempt
                    )
                } else if shouldScheduleTransientDatabaseRecovery {
                    self.scheduleTransientDatabaseRecovery(
                        attempt: (transientRecoveryAttempt ?? 0) + 1,
                        includePreciseScan: transientRecoveryIncludePreciseScan,
                        forceFullTimeSeries: transientRecoveryForceFullTimeSeries
                    )
                }
            }
        }
    }

    private func scheduleTransientDatabaseRecovery(
        attempt: Int,
        includePreciseScan: Bool = true,
        forceFullTimeSeries: Bool = true
    ) {
        transientDatabaseRecoveryTask?.cancel()
        guard backgroundActivityEnabled else {
            transientDatabaseRecoveryTask = nil
            return
        }
        let exponent = max(0, attempt - 1)
        let delay = min(
            16,
            transientDatabaseRecoveryDelay * pow(2, Double(exponent))
        )
        transientDatabaseRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.backgroundActivityEnabled else { return }
            self.transientDatabaseRecoveryTask = nil
            self.refresh(
                includePreciseScan: includePreciseScan,
                forceFullTimeSeries: forceFullTimeSeries,
                transientRecoveryAttempt: attempt
            )
        }
    }

    private func isCurrentRefresh(
        generation: Int,
        bindingGeneration: Int,
        sourceID: String
    ) -> Bool {
        !Task.isCancelled
            && refreshGeneration == generation
            && sourceBindingGeneration == bindingGeneration
            && activeRefreshSourceID == sourceID
    }

    private func refreshSourceID(for dataSource: CodexDataSource) -> String {
        dataSource.stableIdentityKey
    }

    private func publish(
        _ snapshot: DashboardSnapshot,
        todayModelBreakdowns: [ModelTokenBreakdown]? = nil,
        sourceID: String
    ) {
        let availableRows = todayModelBreakdowns
            ?? Self.todayModelBreakdownsIfAvailable(in: snapshot, now: snapshot.generatedAt)
        if let availableRows {
            let hasTodayUsage = Self.todayTokenCount(in: snapshot, now: snapshot.generatedAt) > 0
            let shouldRetainPrevious = availableRows.isEmpty
                && hasTodayUsage
                && !self.todayModelBreakdowns.isEmpty
                && snapshotSourceID == sourceID
                && todayModelBreakdownsDay == Self.startOfDay(snapshot.generatedAt)
            if !shouldRetainPrevious {
                self.todayModelBreakdowns = availableRows
                todayModelBreakdownsDay = Self.startOfDay(snapshot.generatedAt)
            }
        }
        self.snapshot = snapshot
        snapshotSourceID = sourceID
    }

    private static func todayModelBreakdownsIfAvailable(
        in snapshot: DashboardSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> [ModelTokenBreakdown]? {
        guard snapshot.cacheUsage.attributionEventsComplete else { return nil }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return ModelUsagePresentation.rows(
            from: snapshot.cacheUsage.attributionEvents.filter {
                $0.start >= start && $0.start < end
            }
        )
    }

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func todayTokenCount(
        in snapshot: DashboardSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        snapshot.dailyUsage.first {
            calendar.isDate($0.date, inSameDayAs: now)
        }?.tokens ?? 0
    }

    private func clearStaleTodayModelBreakdownsIfNeeded() {
        guard let todayModelBreakdownsDay,
              !Calendar.current.isDate(todayModelBreakdownsDay, inSameDayAs: Date()) else {
            return
        }
        todayModelBreakdowns = []
        self.todayModelBreakdownsDay = nil
    }

    private func prepareAfterObserverTakeover(for source: CodexDataSource) {
        // The previous owner may have observed a short-lived local JSONL that
        // disappeared before this process acquired the lock. A new observation
        // ID invalidates every old ready segment; the durable gap and forced
        // full scan establish the only safe path back to attribution.
        preciseObservationSessionID = UUID()
        sessionMutationMonitoringActive = backgroundActivityEnabled
        configureSessionMutationMonitor()
        markPreciseTimeSeriesContinuityLoss(
            for: source,
            reason: .observerTakeover
        )
        preciseTimeSeriesFresh = false
        isCompactSummaryPending = false
    }

    private func restartWithForcedPreciseRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        activeRefreshSourceID = nil
        activeRefreshCompactOnly = false
        pendingFullRefresh = false
        isRefreshing = false
        isDetailHydrating = false
        isPreparingUsageCache = false
        isCompactSummaryPending = false
        refresh(includePreciseScan: true, forceFullTimeSeries: true)
    }

    /// Clear a persisted continuity loss only after the attribution segment
    /// store has durably replaced the unknown interval with a pending baseline.
    func acknowledgePreciseTimeSeriesContinuityLoss(id: UUID) {
        guard let dataSource,
              preciseTimeSeriesContinuityLossID == id else { return }
        let acknowledgedReason = preciseTimeSeriesContinuityLossReason
        if continuitySafetyDatabase != nil {
            let removed = mutateContinuityLosses { values -> Bool in
                let identifier = Self.continuityIdentifier(for: dataSource)
                guard values[identifier]?.id == id else { return false }
                values.removeValue(forKey: identifier)
                return true
            }
            if removed == true {
                preciseTimeSeriesContinuityLostAt = nil
                preciseTimeSeriesContinuityLossID = nil
                preciseTimeSeriesContinuityLossReason = nil
                if acknowledgedReason == .storageRecovery {
                    sharedAccountSafetyRecoveryState = .idle
                }
            }
            return
        }
        guard var values = continuityLosses() else { return }
        values.removeValue(forKey: Self.continuityIdentifier(for: dataSource))
        if persistContinuityLosses(values) {
            preciseTimeSeriesContinuityLostAt = nil
            preciseTimeSeriesContinuityLossID = nil
            preciseTimeSeriesContinuityLossReason = nil
            if acknowledgedReason == .storageRecovery {
                sharedAccountSafetyRecoveryState = .idle
            }
        }
    }

    private func markPreciseTimeSeriesContinuityLoss(
        for source: CodexDataSource,
        detectedAt: Date = Date(),
        reason: PreciseTimeSeriesContinuityLossReason = .observationGap
    ) {
        // This timestamp identifies the latest failed exact-read generation;
        // segment bounds are derived from the later successful recovery scan.
        // Updating it on another failure lets that distinct unknown interval
        // replace an in-flight cutover instead of being silently acknowledged.
        let loss = PreciseTimeSeriesContinuityLossRecord(
            id: UUID(),
            detectedAt: detectedAt,
            reason: reason
        )
        let identifier = Self.continuityIdentifier(for: source)
        if let continuitySafetyDatabase {
            let safetyLock = continuitySafetyDatabase.acquireCrossProcessLock(
                waitingUpTo: 2
            )
            defer { safetyLock?.release() }
            // Lock contention is an availability concern, never permission to
            // drop a safety event. SQLite's atomic mutation remains durable and
            // emits a distributed invalidation even if another process holds
            // the wider attribution-computation lock longer than the UI wait.
            let persisted = mutateContinuityLosses { values -> Bool in
                values[identifier] = loss
                return true
            }
            if persisted == true,
               dataSource?.stableIdentityKey == source.stableIdentityKey {
                preciseTimeSeriesContinuityLostAt = loss.detectedAt
                preciseTimeSeriesContinuityLossID = loss.id
                preciseTimeSeriesContinuityLossReason = loss.reason
            } else if persisted == nil {
                // The durable write failed. Keep the unknown interval visible
                // in memory and fail attribution closed for this process.
                preciseTimeSeriesContinuityLostAt = loss.detectedAt
                preciseTimeSeriesContinuityLossID = loss.id
                preciseTimeSeriesContinuityLossReason = loss.reason
            }
            return
        }
        guard var values = continuityLosses() else {
            preciseTimeSeriesContinuityLostAt = loss.detectedAt
            preciseTimeSeriesContinuityLossID = loss.id
            preciseTimeSeriesContinuityLossReason = loss.reason
            return
        }
        values[identifier] = loss
        if persistContinuityLosses(values),
           dataSource?.stableIdentityKey == source.stableIdentityKey {
            preciseTimeSeriesContinuityLostAt = loss.detectedAt
            preciseTimeSeriesContinuityLossID = loss.id
            preciseTimeSeriesContinuityLossReason = loss.reason
        }
    }

    private func loadContinuityLoss(for source: CodexDataSource?) {
        guard migrateLegacyContinuityLossesIfNeeded() else {
            preciseTimeSeriesContinuityLostAt = nil
            preciseTimeSeriesContinuityLossID = nil
            preciseTimeSeriesContinuityLossReason = nil
            return
        }
        guard let source,
              let loss = continuityLosses()?[Self.continuityIdentifier(for: source)] else {
            preciseTimeSeriesContinuityLostAt = nil
            preciseTimeSeriesContinuityLossID = nil
            preciseTimeSeriesContinuityLossReason = nil
            return
        }
        preciseTimeSeriesContinuityLostAt = loss.detectedAt
        preciseTimeSeriesContinuityLossID = loss.id
        preciseTimeSeriesContinuityLossReason = loss.reason
        if loss.reason == .storageRecovery,
           sharedAccountSafetyRecoveryState != .rebuilding {
            sharedAccountSafetyRecoveryState = .awaitingFreshBaseline
        }
    }

    private func migrateLegacyContinuityLossesIfNeeded() -> Bool {
        if let continuitySafetyDatabase {
            if continuitySafetyDatabase.load(.preciseContinuity) != nil {
                guard retireContinuityDefaultsMigrationSources() else {
                    continuitySafetyDatabase.reportRecoveryRequired()
                    preciseContinuityPersistenceHealthy = false
                    return false
                }
                preciseContinuityPersistenceHealthy = true
                return true
            }
            guard continuitySafetyDatabase.persistenceHealthy else {
                preciseContinuityPersistenceHealthy = false
                return false
            }
            let migrationData: Data
            if let currentData = continuityDefaults.data(forKey: continuityStorageKey) {
                guard (try? JSONDecoder().decode(
                    [String: PreciseTimeSeriesContinuityLossRecord].self,
                    from: currentData
                )) != nil else {
                    continuitySafetyDatabase.reportRecoveryRequired()
                    preciseContinuityPersistenceHealthy = false
                    return false
                }
                migrationData = currentData
            } else if let legacyContinuityStorageKey,
                      let legacyData = continuityDefaults.data(forKey: legacyContinuityStorageKey) {
                guard let legacy = try? JSONDecoder().decode([String: Date].self, from: legacyData),
                      let migratedData = try? JSONEncoder().encode(
                    legacy.mapValues {
                        PreciseTimeSeriesContinuityLossRecord(id: UUID(), detectedAt: $0)
                    }
                ) else {
                    continuitySafetyDatabase.reportRecoveryRequired()
                    preciseContinuityPersistenceHealthy = false
                    return false
                }
                migrationData = migratedData
            } else {
                guard let emptyData = try? JSONEncoder().encode(
                    [String: PreciseTimeSeriesContinuityLossRecord]()
                ) else {
                    continuitySafetyDatabase.reportRecoveryRequired()
                    preciseContinuityPersistenceHealthy = false
                    return false
                }
                migrationData = emptyData
            }
            let installed = continuitySafetyDatabase.mutate(.preciseContinuity) { existing in
                let authoritative = existing ?? migrationData
                return (authoritative, authoritative)
            }
            guard let installed,
                  continuitySafetyDatabase.load(.preciseContinuity) == installed,
                  retireContinuityDefaultsMigrationSources() else {
                continuitySafetyDatabase.reportRecoveryRequired()
                preciseContinuityPersistenceHealthy = false
                return false
            }
            preciseContinuityPersistenceHealthy = true
            return true
        }

        guard continuityDefaults.data(forKey: continuityStorageKey) == nil,
              let legacyContinuityStorageKey,
              let legacyData = continuityDefaults.data(forKey: legacyContinuityStorageKey) else {
            return true
        }
        guard let legacy = try? JSONDecoder().decode([String: Date].self, from: legacyData) else {
            preciseContinuityPersistenceHealthy = false
            return false
        }
        let migrated = legacy.mapValues {
            PreciseTimeSeriesContinuityLossRecord(id: UUID(), detectedAt: $0)
        }
        guard persistContinuityLosses(migrated) else { return false }
        continuityDefaults.removeObject(forKey: legacyContinuityStorageKey)
        guard continuityDefaults.data(forKey: legacyContinuityStorageKey) == nil else {
            preciseContinuityPersistenceHealthy = false
            return false
        }
        return true
    }

    private func retireContinuityDefaultsMigrationSources() -> Bool {
        let keys = [continuityStorageKey, legacyContinuityStorageKey]
            .compactMap { $0 }
        for key in keys where continuityDefaults.object(forKey: key) != nil {
            continuityDefaults.removeObject(forKey: key)
            guard continuityDefaults.object(forKey: key) == nil else {
                continuitySafetyDatabase?.reportRecoveryRequired()
                return false
            }
        }
        return true
    }

    private func continuityLosses() -> [String: PreciseTimeSeriesContinuityLossRecord]? {
        if let continuitySafetyDatabase {
            guard let data = continuitySafetyDatabase.load(.preciseContinuity) else {
                preciseContinuityPersistenceHealthy = continuitySafetyDatabase.persistenceHealthy
                return continuitySafetyDatabase.persistenceHealthy ? [:] : nil
            }
            guard let values = try? JSONDecoder().decode(
                [String: PreciseTimeSeriesContinuityLossRecord].self,
                from: data
            ) else {
                continuitySafetyDatabase.reportCorruptPayload(.preciseContinuity)
                preciseContinuityPersistenceHealthy = false
                return nil
            }
            preciseContinuityPersistenceHealthy = true
            return values
        }
        guard let data = continuityDefaults.data(forKey: continuityStorageKey) else {
            preciseContinuityPersistenceHealthy = true
            return [:]
        }
        guard let values = try? JSONDecoder().decode(
            [String: PreciseTimeSeriesContinuityLossRecord].self,
            from: data
        ) else {
            preciseContinuityPersistenceHealthy = false
            return nil
        }
        preciseContinuityPersistenceHealthy = true
        return values
    }

    @discardableResult
    private func persistContinuityLosses(
        _ values: [String: PreciseTimeSeriesContinuityLossRecord]
    ) -> Bool {
        if let continuitySafetyDatabase {
            guard let data = try? JSONEncoder().encode(values) else {
                preciseContinuityPersistenceHealthy = false
                return false
            }
            let succeeded = continuitySafetyDatabase.store(data, as: .preciseContinuity)
            preciseContinuityPersistenceHealthy = succeeded
                && continuitySafetyDatabase.persistenceHealthy
            return preciseContinuityPersistenceHealthy
        }
        if values.isEmpty {
            continuityDefaults.removeObject(forKey: continuityStorageKey)
            let succeeded = continuityDefaults.data(forKey: continuityStorageKey) == nil
            preciseContinuityPersistenceHealthy = succeeded
            return succeeded
        }
        guard let data = try? JSONEncoder().encode(values) else {
            preciseContinuityPersistenceHealthy = false
            return false
        }
        continuityDefaults.set(data, forKey: continuityStorageKey)
        guard continuityDefaults.data(forKey: continuityStorageKey) == data,
              let decoded = try? JSONDecoder().decode(
                [String: PreciseTimeSeriesContinuityLossRecord].self,
                from: data
              ),
              decoded == values else {
            preciseContinuityPersistenceHealthy = false
            return false
        }
        preciseContinuityPersistenceHealthy = true
        return true
    }

    private func mutateContinuityLosses<Result>(
        _ body: (inout [String: PreciseTimeSeriesContinuityLossRecord]) throws -> Result
    ) -> Result? {
        guard let continuitySafetyDatabase else { return nil }
        let result = continuitySafetyDatabase.mutate(.preciseContinuity) { data in
            var values: [String: PreciseTimeSeriesContinuityLossRecord]
            if let data {
                guard let decoded = try? JSONDecoder().decode(
                    [String: PreciseTimeSeriesContinuityLossRecord].self,
                    from: data
                ) else {
                    throw SharedAccountUsageSafetyStorageError.corruptPayload
                }
                values = decoded
            } else {
                values = [:]
            }
            let result = try body(&values)
            return (try JSONEncoder().encode(values), result)
        }
        preciseContinuityPersistenceHealthy = result != nil
            && continuitySafetyDatabase.persistenceHealthy
        return result
    }

    nonisolated static func continuityIdentifier(for source: CodexDataSource) -> String {
        SHA256.hash(data: Data(source.stableIdentityKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // 轻量 summary 只覆盖紧凑 surface 消费的字段（累计 token、今日 token/
    // 调用数与今日逐模型用量）；时间序列/排行/摘录保留上次全量构建结果，展开仪表盘时由
    // setOnlyCompactSurfaceVisible 触发的全量刷新补齐。
    static func applyingCompactSummary(
        _ summary: CodexUsageAnalyzer.CompactUsageSummary,
        to previous: DashboardSnapshot
    ) -> DashboardSnapshot {
        let calendar = Calendar.current
        var dailyUsage = previous.dailyUsage
        let todayEntry = DayUsage(
            date: calendar.startOfDay(for: summary.generatedAt),
            tokens: summary.todayTokens,
            calls: summary.todayCalls
        )
        if let index = dailyUsage.firstIndex(where: {
            calendar.isDate($0.date, inSameDayAs: summary.generatedAt)
        }) {
            dailyUsage[index] = todayEntry
        } else {
            dailyUsage.append(todayEntry)
        }
        let stats = DashboardStats(
            totalTokens: summary.totalTokens,
            peakDayTokens: max(previous.stats.peakDayTokens, summary.todayTokens),
            peakThreadTokens: previous.stats.peakThreadTokens,
            currentStreakDays: previous.stats.currentStreakDays,
            longestStreakDays: previous.stats.longestStreakDays,
            totalCalls: previous.stats.totalCalls,
            totalThreads: previous.stats.totalThreads,
            mostUsedReasoning: previous.stats.mostUsedReasoning,
            skillsExplored: previous.stats.skillsExplored,
            totalSkillsUsed: previous.stats.totalSkillsUsed,
            totalInputTokens: previous.stats.totalInputTokens,
            totalCachedInputTokens: previous.stats.totalCachedInputTokens,
            totalOutputTokens: previous.stats.totalOutputTokens,
            firstUsageAt: previous.stats.firstUsageAt
        )
        return DashboardSnapshot(
            stats: stats,
            dailyUsage: dailyUsage,
            recentBins: previous.recentBins,
            hourlyUsage: previous.hourlyUsage,
            pluginUsage: previous.pluginUsage,
            cacheUsage: previous.cacheUsage,
            usagePrecision: previous.usagePrecision,
            preciseTimeSeriesGeneratedAt: previous.preciseTimeSeriesGeneratedAt,
            generatedAt: summary.generatedAt
        )
    }

    private func hasDisplayableSnapshot(_ snapshot: DashboardSnapshot) -> Bool {
        snapshot.stats.totalTokens > 0
            || snapshot.stats.totalThreads > 0
            || !snapshot.dailyUsage.isEmpty
            || !snapshot.recentBins.isEmpty
            || !snapshot.hourlyUsage.isEmpty
    }

    private func metadataOnlyStatus(origin: String) -> String {
        "\(origin) · state_5.sqlite · 仅显示会话元数据，精确 token 仍在读取..."
    }

    private func applyFastSnapshotFreshness(
        _ result: DashboardFastSnapshotResult
    ) {
        isCompactSummaryPending = false
        switch result.freshness {
        case .current:
            preciseTimeSeriesFresh = result.snapshot.hasPreciseTokenUsage
                && result.snapshot.preciseTimeSeriesGeneratedAt != nil
        case .staleCompatible, .unavailable:
            preciseTimeSeriesFresh = false
        }
    }

    private func fastSnapshotStatus(
        _ result: DashboardFastSnapshotResult,
        origin: String,
        preciseFollowUp: String
    ) -> String {
        switch result.freshness {
        case .current:
            return result.snapshot.hasPreciseTokenUsage
                ? "\(origin) · token_count · \(preciseFollowUp)"
                : metadataOnlyStatus(origin: origin)
        case .staleCompatible:
            return "\(origin) · token_count · 正在核对上次精确数据（保留旧值）..."
        case .unavailable:
            return metadataOnlyStatus(origin: origin)
        }
    }

    private func staleMetadataOnlyStatus(origin: String) -> String {
        "\(origin) · 用量已陈旧 · 当前仅元数据，保留上次可信 token"
    }

    private func scheduleInitialPreciseRefresh() {
        initialPreciseTask?.cancel()
        initialPreciseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.backgroundActivityEnabled else { return }

            while self.isRefreshing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard !Task.isCancelled, self.backgroundActivityEnabled, !self.didRunPreciseScan else { return }
            self.refresh()
        }
    }

    func chooseDataSourceDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据目录"
        panel.message = "请选择包含 sessions 文件夹的 Codex Home，例如 ~/.codex。"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = dataSource?.codexHome ?? FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDataSource(resolver.saveSelectedDirectory(url))
        refresh()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard abs(refreshInterval - interval) > 0.5 else { return }
        refreshInterval = interval
        scheduleTimer()
    }

    func setBackgroundActivityEnabled(_ enabled: Bool) {
        guard backgroundActivityEnabled != enabled else { return }
        backgroundActivityEnabled = enabled
        if enabled {
            // A monitoring pause can hide a short-lived local session. Rotate
            // the observer session before the first resumed scan so attribution
            // establishes one new synthetic baseline for the uncovered gap.
            preciseObservationSessionID = UUID()
            sessionMutationMonitoringActive = true
            configureSessionMutationMonitor()
            scheduleTimer()
            refresh()
        } else {
            sessionMutationMonitoringActive = false
            sessionMutationMonitor.stop()
            preciseSessionMutationMonitoringHealthy = false
            attributionSafetyAckTask?.cancel()
            attributionSafetyAckTask = nil
            pendingAttributionSafetyAckKey = nil
            timer?.invalidate()
            timer = nil
            initialPreciseTask?.cancel()
            initialPreciseTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            transientDatabaseRecoveryTask?.cancel()
            transientDatabaseRecoveryTask = nil
            refreshGeneration += 1
            activeRefreshSourceID = nil
            activeRefreshCompactOnly = false
            pendingFullRefresh = false
            isRefreshing = false
            isDetailHydrating = false
            isPreparingUsageCache = false
            isCompactSummaryPending = false
            // Cancellation is an intentional pause, not an in-flight
            // migration.  Clear the ephemeral progress state so the header
            // cannot remain stuck on preparing/scanning after background work
            // has been disabled.
            preciseIndexProgress = .idle
        }
    }

    private func configureSessionMutationMonitor() {
        guard sessionMutationMonitoringActive,
              backgroundActivityEnabled,
              (continuitySafetyDatabase?.isObserverOwner ?? true),
              let dataSource else {
            sessionMutationMonitor.stop()
            preciseSessionMutationMonitoringHealthy = false
            return
        }
        let home = dataSource.codexHome.standardizedFileURL
        preciseSessionMutationMonitoringHealthy = sessionMutationMonitor.start(
            // Exact discovery may include state_5 rollout_path values outside
            // sessions/archived_sessions. Watching the canonical Home catches
            // new parent folders as well as short-lived external JSONLs.
            roots: [home]
        ) { [weak self] detectedAt in
            Task { @MainActor [weak self] in
                guard let self,
                      self.backgroundActivityEnabled,
                      let source = self.dataSource else { return }
                self.reloadPreciseTimeSeriesContinuityLoss()
                guard self.preciseTimeSeriesContinuityLossID == nil else { return }
                self.markPreciseTimeSeriesContinuityLoss(
                    for: source,
                    detectedAt: detectedAt
                )
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard backgroundActivityEnabled else {
            timer = nil
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func updateDataSourceLabels() {
        guard let dataSource else {
            dataSourceLabel = "未发现 Codex 目录"
            dataSourceOrigin = "需更改目录"
            return
        }

        dataSourceLabel = dataSource.displayPath
        dataSourceOrigin = dataSource.originLabel
    }
}

enum ActivityMode: String, CaseIterable, Identifiable {
    case daily = "每日"
    case weekly = "每周"
    case cumulative = "累计"
    case modelShare = "模型"
    case modelCost = "费用"
    case cacheHitRate = "命中率"
    case quotaRemaining = "额度"

    var id: String { rawValue }

    var isSpecial: Bool {
        self == .modelShare || self == .modelCost || self == .cacheHitRate || self == .quotaRemaining
    }
}

extension DashboardSnapshot {
    static let empty = DashboardSnapshot(
        stats: DashboardStats(
            totalTokens: 0,
            peakDayTokens: 0,
            peakThreadTokens: 0,
            currentStreakDays: 0,
            longestStreakDays: 0,
            totalCalls: 0,
            totalThreads: 0,
            mostUsedReasoning: "未知",
            skillsExplored: 0,
            totalSkillsUsed: 0
        ),
        dailyUsage: [],
        recentBins: [],
        hourlyUsage: [],
        pluginUsage: [],
        cacheUsage: .empty,
        usagePrecision: .metadataOnly,
        generatedAt: Date()
    )

    static let sample: DashboardSnapshot = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<365).compactMap { offset -> DayUsage? in
            guard let date = calendar.date(byAdding: .day, value: -364 + offset, to: today) else { return nil }
            let wave = max(0, sin(Double(offset) / 18.0))
            let spike = offset > 330 ? Double((offset % 7) + 1) / 7.0 : 0
            let tokens = Int((wave * 2_000_000) + (spike * 8_000_000))
            return DayUsage(date: date, tokens: tokens, calls: tokens == 0 ? 0 : max(1, tokens / 120_000))
        }

        let bins = (0..<288).compactMap { index -> BinUsage? in
            guard let date = calendar.date(byAdding: .minute, value: -5 * (287 - index), to: Date()) else { return nil }
            let tokens = index % 36 == 0 ? 9_800_000 : Int.random(in: 20_000...900_000)
            return BinUsage(start: date, tokens: tokens, calls: max(1, tokens / 110_000))
        }
        let currentHour = calendar.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let hourlyBins = (0..<720).compactMap { index -> BinUsage? in
            guard let date = calendar.date(byAdding: .hour, value: -719 + index, to: currentHour) else { return nil }
            let dayWave = max(0, sin(Double(index) / 21.0))
            let recentLift = index > 650 ? Double(index - 650) / 70.0 : 0
            let tokens = Int(dayWave * 1_200_000 + recentLift * 2_400_000)
            return BinUsage(start: date, tokens: tokens, calls: tokens == 0 ? 0 : max(1, tokens / 115_000))
        }
        let cacheUsage = sampleCacheUsage(days: days, bins: bins, hourlyBins: hourlyBins)

        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: days.reduce(0) { $0 + $1.tokens },
                peakDayTokens: days.map(\.tokens).max() ?? 0,
                peakThreadTokens: 94_000_000,
                currentStreakDays: 26,
                longestStreakDays: 26,
                totalCalls: bins.reduce(0) { $0 + $1.calls },
                totalThreads: 13_040,
                mostUsedReasoning: "中 · 51%",
                skillsExplored: 11,
                totalSkillsUsed: 31,
                totalInputTokens: cacheUsage.total.inputTokens,
                totalCachedInputTokens: cacheUsage.total.cachedInputTokens,
                totalOutputTokens: cacheUsage.total.outputTokens,
                firstUsageAt: days.first(where: { $0.tokens > 0 })?.date
            ),
            dailyUsage: days,
            recentBins: bins,
            hourlyUsage: hourlyBins,
            pluginUsage: [
                PluginUsage(name: "@documents", runs: 6),
                PluginUsage(name: "@spreadsheets", runs: 5),
                PluginUsage(name: "$paper-spine-translate-en", runs: 5),
                PluginUsage(name: "@presentations", runs: 3),
                PluginUsage(name: "$paper-spine", runs: 3)
            ],
            cacheUsage: cacheUsage,
            generatedAt: Date()
        )
    }()

    private static func sampleCacheUsage(days: [DayUsage], bins: [BinUsage], hourlyBins: [BinUsage]) -> TokenCacheUsage {
        func breakdown(totalTokens: Int, calls: Int, cacheRate: Double) -> TokenCacheBreakdown {
            let inputTokens = Int(Double(totalTokens) * 0.94)
            let outputTokens = max(totalTokens - inputTokens, 0)
            let cachedInputTokens = Int(Double(inputTokens) * cacheRate)
            return TokenCacheBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: Int(Double(outputTokens) * 0.28),
                totalTokens: totalTokens,
                calls: calls
            )
        }

        let daily = days
            .filter { $0.tokens > 0 }
            .map { day in
                TokenCacheBucket(
                    start: day.date,
                    breakdown: breakdown(totalTokens: day.tokens, calls: day.calls, cacheRate: 0.86)
                )
            }

        let hourly = hourlyBins
            .filter { $0.tokens > 0 }
            .map { bin in
                TokenCacheBucket(
                    start: bin.start,
                    breakdown: breakdown(totalTokens: bin.tokens, calls: bin.calls, cacheRate: 0.9)
                )
            }

        let sessions = (0..<6).map { index in
            let total = 1_800_000 + index * 420_000
            return SessionCacheUsage(
                id: "sample-\(index)",
                title: "示例会话 \(index + 1)",
                lastUpdated: Calendar.current.date(byAdding: .hour, value: -index * 3, to: Date()),
                breakdown: breakdown(totalTokens: total, calls: 4 + index, cacheRate: 0.82 + Double(index) * 0.02)
            )
        }
        var sampleTurnIndexBySession: [String: Int] = [:]
        let turns = (0..<10).compactMap { index -> TurnCacheUsage? in
            guard let timestamp = Calendar.current.date(byAdding: .minute, value: -index * 38, to: Date()) else {
                return nil
            }
            let sessionID = "sample-\(index % 6)"
            let turnIndex = (sampleTurnIndexBySession[sessionID] ?? 0) + 1
            sampleTurnIndexBySession[sessionID] = turnIndex
            let total = 260_000 + index * 42_000
            return TurnCacheUsage(
                id: "sample-turn-\(index)",
                sessionID: sessionID,
                sessionTitle: "示例会话 \((index % 6) + 1)",
                timestamp: timestamp,
                turnIndexInSession: turnIndex,
                userPrompt: "为什么今天的缓存命中率偏低？",
                assistantResponse: "我会先按会话和轮次拆开看，找到输入增长但缓存没有复用的地方。",
                breakdown: breakdown(totalTokens: total, calls: 1, cacheRate: 0.78 + Double(index % 5) * 0.04)
            )
        }

        let total = daily.reduce(TokenCacheBreakdown.empty) { partial, bucket in
            TokenCacheBreakdown(
                inputTokens: partial.inputTokens + bucket.breakdown.inputTokens,
                cachedInputTokens: partial.cachedInputTokens + bucket.breakdown.cachedInputTokens,
                outputTokens: partial.outputTokens + bucket.breakdown.outputTokens,
                reasoningOutputTokens: partial.reasoningOutputTokens + bucket.breakdown.reasoningOutputTokens,
                totalTokens: partial.totalTokens + bucket.breakdown.totalTokens,
                calls: partial.calls + bucket.breakdown.calls
            )
        }

        let recentBins = bins.map { bin in
            TokenCacheBucket(
                start: bin.start,
                breakdown: breakdown(totalTokens: bin.tokens, calls: bin.calls, cacheRate: 0.9)
            )
        }

        return TokenCacheUsage(total: total, daily: daily, hourly: hourly, recentBins: recentBins, sessions: sessions, turns: turns)
    }
}
