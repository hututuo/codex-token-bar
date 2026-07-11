import Foundation
import Darwin
import SwiftUI
import TiktokenSwift

@MainActor
final class LiveRateMonitor: ObservableObject {
    enum DisplayRateScope {
        case selectedSession
        case allSessions
    }

    @Published var snapshot = LiveRateSnapshot()
    @Published var totalSnapshot = LiveRateSnapshot(
        threadTitle: "全会话输出汇总",
        status: "等待任意会话输出",
        scopeLabel: "全会话"
    )
    @Published private(set) var threadOptions: [LiveThreadOption] = []
    @Published private(set) var selectedThreadID = ""
    @Published private(set) var preciseTokenCountingEnabled: Bool
    @Published private(set) var monitoringEnabled: Bool

    private let resolver = CodexDataSourceResolver()
    let logReaderFactory: LiveRateLogReaderMaking
    private let recentThreadsLoader: @Sendable (String) throws -> [ThreadRow]
    var dataSource: CodexDataSource?
    var compositionDataSourceBound = false
    var sourceGeneration = 0
    var sourceBindingGeneration = 0
    let windowSeconds: TimeInterval = 2.5
    private let fastPollInterval: TimeInterval = 0.25
    private let idlePollInterval: TimeInterval = 1.0
    private let idleFallbackPollInterval: TimeInterval = 2.0
    private let rolloutFallbackPollInterval: TimeInterval = 1.0
    let activeFastPollHoldSeconds: TimeInterval = 10.0
    private let snapshotPublishInterval: TimeInterval = 0.25
    private let startupBackfillSeconds: TimeInterval = 4.0
    private let minimumRateSpanSeconds: TimeInterval = 0.4
    nonisolated private static let selectedSessionDisplayRateCap: Double = 80
    nonisolated static let unattributedLiveRateSessionKey = "unattributed-stream"
    private var timer: Timer?
    var logsDirectorySource: DispatchSourceFileSystemObject?
    var watchedLogsDirectory = ""
    var cachedLogsDatabasePath = ""
    var cachedLogsDirectoryPath = ""
    var logChangePending = false
    var fastPollUntil: TimeInterval = 0
    private var threadID = ""
    private var lastLogID = 0
    private var lastGlobalLogID = 0
    private var lastLogsSignature: LogStoreSignature?
    private var lastThreadOptionsSignature: LogStoreSignature?
    private var lastThreadOptionsRefreshAt: TimeInterval = 0
    private let threadOptionsRefreshTTL: TimeInterval = 5
    private var lastPollProcessedRows = false
    private var lastSnapshotPublishAt: TimeInterval = 0
    private var lastFallbackPollAt: TimeInterval = 0
    private var lastRolloutReadAt: TimeInterval = 0
    private var pollInProgress = false
    var logReader: LiveRateLogReading?
    var selectedRate = RateAccumulator(resetsOnNewItem: false)
    var totalRate = RateAccumulator(resetsOnNewItem: false)
    var totalSessionRates: [String: RateAccumulator] = [:]
    private var selectedSmoothedTokensPerSecond: Double = 0
    private var totalSmoothedTokensPerSecond: Double = 0
    private var rolloutOffsets: [String: UInt64] = [:]
    var turnThreadIDs: [String: String] = [:]
    var itemTurnIDs: [String: String] = [:]
    var itemThreadIDs: [String: String] = [:]
    var itemToolNames: [String: String] = [:]
    var itemCallIDs: [String: String] = [:]
    var countedStreamFingerprints = RecentFingerprintSet(limit: 4_096)
    var countedRolloutFingerprints = RecentFingerprintSet(limit: 4_096)
    var countedStreamVisibleFingerprints = RecentFingerprintSet(limit: 4_096)
    var countedRolloutVisibleFingerprints = RecentFingerprintSet(limit: 4_096)
    var visibleStreamAssemblies = RecentVisibleTextAssemblies(limit: 1_024)
    private struct PendingRolloutCompletion {
        let event: RolloutMetricEvent
        let threadID: String
        let enqueuedAt: TimeInterval
    }
    private var pendingRolloutCompletions: [String: PendingRolloutCompletion] = [:]
    private var pendingRolloutOrder: [String] = []
    private let pendingRolloutWindow: TimeInterval = 1.0
    private let pendingRolloutLimit = 1_024
    var tokenEncoder: CoreBpe?

    struct FileStoreSignature: Equatable {
        let device: UInt64?
        let inode: UInt64?
        let size: UInt64
        let modifiedAt: TimeInterval

        var physicalIdentity: String? {
            guard let device, let inode else { return nil }
            return "\(device):\(inode)"
        }
    }

    struct LogStoreSignature: Equatable {
        let database: FileStoreSignature
        let wal: FileStoreSignature

        func isPhysicalDatabaseReplacement(comparedTo previous: LogStoreSignature) -> Bool {
            database.physicalIdentity != previous.database.physicalIdentity
        }
    }

    init(
        preciseTokenCountingEnabled: Bool = LiveRateMonitor.defaultPreciseTokenCountingEnabled(),
        monitoringEnabled: Bool = LiveRateMonitor.defaultMonitoringEnabled(),
        logReaderFactory: LiveRateLogReaderMaking = DefaultLiveRateLogReaderFactory(),
        recentThreadsLoader: @escaping @Sendable (String) throws -> [ThreadRow] = { stateDB in
            try LiveRateMonitor.recentThreads(stateDB: stateDB)
        }
    ) {
        self.preciseTokenCountingEnabled = preciseTokenCountingEnabled
        self.monitoringEnabled = monitoringEnabled
        self.logReaderFactory = logReaderFactory
        self.recentThreadsLoader = recentThreadsLoader
        Task {
            updateTokenCountingLabel()
            if monitoringEnabled {
                start()
            } else {
                disableMonitoringSnapshots()
            }
            if preciseTokenCountingEnabled {
                await warmTokenEncoder()
            }
        }
    }

    var currentDataSourceIdentity: String? {
        dataSource?.stableIdentityKey
    }

    private static func defaultPreciseTokenCountingEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: "preciseTokenCountingEnabled") != nil else {
            return false
        }
        return UserDefaults.standard.bool(forKey: "preciseTokenCountingEnabled")
    }

    private static func defaultMonitoringEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: "liveRateMonitoringEnabled") != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: "liveRateMonitoringEnabled")
    }

    func start() {
        guard monitoringEnabled else { return }
        timer?.invalidate()
        scheduleNextPoll(after: 0.02)
    }

    func scheduleNextPoll(after interval: TimeInterval) {
        guard monitoringEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitoringEnabled else { return }
                await self.poll()
                self.scheduleNextPoll(after: self.nextPollInterval())
            }
        }
    }

    private func nextPollInterval() -> TimeInterval {
        let now = Date().timeIntervalSince1970
        if logChangePending || now < fastPollUntil || hasActiveRollingWindow(now: now) {
            return fastPollInterval
        }
        return idlePollInterval
    }

    func reset() {
        Task {
            await resetToLatestThread()
        }
    }

    func selectThread(_ id: String) {
        guard id != threadID else { return }
        Task {
            await switchToThread(id)
        }
    }

    func setPreciseTokenCountingEnabled(_ enabled: Bool) {
        guard enabled != preciseTokenCountingEnabled else { return }
        preciseTokenCountingEnabled = enabled
        selectedRate.clear()
        totalRate.clear()
        totalSessionRates.removeAll()
        selectedSmoothedTokensPerSecond = 0
        totalSmoothedTokensPerSecond = 0
        if enabled {
            Task { await warmTokenEncoder() }
        } else {
            tokenEncoder = nil
            updateTokenCountingLabel()
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        guard enabled != monitoringEnabled else { return }
        monitoringEnabled = enabled
        if enabled {
            selectedRate.clear()
            totalRate.clear()
            selectedSmoothedTokensPerSecond = 0
            totalSmoothedTokensPerSecond = 0
            start()
        } else {
            timer?.invalidate()
            timer = nil
            logsDirectorySource?.cancel()
            logsDirectorySource = nil
            watchedLogsDirectory = ""
            logChangePending = false
            fastPollUntil = 0
            selectedRate.clear()
            totalRate.clear()
            totalSessionRates.removeAll()
            selectedSmoothedTokensPerSecond = 0
            totalSmoothedTokensPerSecond = 0
            clearStreamState()
            disableMonitoringSnapshots()
        }
    }

    func resetSourceLocalState(for source: CodexDataSource?) {
        logsDirectorySource?.cancel()
        logsDirectorySource = nil
        watchedLogsDirectory = ""
        logReader = nil
        logChangePending = false
        fastPollUntil = 0
        threadID = ""
        selectedThreadID = ""
        threadOptions = []
        lastLogID = 0
        lastGlobalLogID = 0
        lastLogsSignature = nil
        lastThreadOptionsSignature = nil
        lastThreadOptionsRefreshAt = 0
        lastPollProcessedRows = false
        lastSnapshotPublishAt = 0
        lastFallbackPollAt = 0
        lastRolloutReadAt = 0
        rolloutOffsets.removeAll()
        selectedRate.clear()
        totalRate.clear()
        totalSessionRates.removeAll()
        selectedSmoothedTokensPerSecond = 0
        totalSmoothedTokensPerSecond = 0
        clearStreamState()

        let interfaceLabel = snapshot.interfaceLabel
        if let source {
            let sourceLabel = "\(source.displayPath)/logs_2.sqlite"
            snapshot = LiveRateSnapshot(
                sourceLabel: sourceLabel,
                status: "等待新数据源会话",
                interfaceLabel: interfaceLabel
            )
            configureTotalSnapshot(source: source)
        } else {
            snapshot = LiveRateSnapshot(
                status: "未找到 Codex 数据目录",
                interfaceLabel: interfaceLabel
            )
            totalSnapshot = LiveRateSnapshot(
                threadTitle: "全会话输出汇总",
                status: "未找到 Codex 数据目录",
                scopeLabel: "全会话",
                interfaceLabel: totalSnapshot.interfaceLabel
            )
            updateTokenCountingLabel()
        }
    }

    func rebindSourcePaths(from previousSource: CodexDataSource?, to source: CodexDataSource?) {
        let oldHome = previousSource?.codexHome.standardizedFileURL.path
        let newHome = source?.codexHome.standardizedFileURL.path

        if let source {
            cachedLogsDatabasePath = source.logsDatabase.standardizedFileURL.path
            cachedLogsDirectoryPath = source.codexHome.standardizedFileURL.path
        } else {
            cachedLogsDatabasePath = ""
            cachedLogsDirectoryPath = ""
        }

        logsDirectorySource?.cancel()
        logsDirectorySource = nil
        watchedLogsDirectory = ""
        logReader = nil
        logChangePending = true
        lastFallbackPollAt = 0
        lastRolloutReadAt = 0

        if let oldHome, let newHome {
            threadOptions = threadOptions.map { option in
                LiveThreadOption(
                    id: option.id,
                    title: option.title,
                    updatedAtMS: option.updatedAtMS,
                    rolloutPath: Self.rebasedPath(option.rolloutPath, from: oldHome, to: newHome)
                )
            }
            var reboundOffsets: [String: UInt64] = [:]
            for (path, offset) in rolloutOffsets {
                let reboundPath = Self.rebasedPath(path, from: oldHome, to: newHome)
                reboundOffsets[reboundPath] = max(reboundOffsets[reboundPath] ?? 0, offset)
            }
            rolloutOffsets = reboundOffsets
        }

        let sourceLabel = source.map { "\($0.displayPath)/logs_2.sqlite" } ?? ""
        snapshot.sourceLabel = sourceLabel
        totalSnapshot.sourceLabel = sourceLabel
        if monitoringEnabled {
            configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
            scheduleNextPoll(after: 0.02)
        }
    }

    private static func rebasedPath(_ path: String, from oldHome: String, to newHome: String) -> String {
        guard path == oldHome || path.hasPrefix(oldHome + "/") else { return path }
        return newHome + String(path.dropFirst(oldHome.count))
    }

    private func monitoringDataSource() -> CodexDataSource? {
        if compositionDataSourceBound {
            return dataSource
        }
        if let dataSource {
            return dataSource
        }
        guard let resolved = resolver.resolve() else {
            return nil
        }
        adoptResolvedDataSource(resolved)
        return resolved
    }

    private func isCurrentSource(
        generation: Int,
        bindingGeneration: Int
    ) -> Bool {
        sourceGeneration == generation
            && sourceBindingGeneration == bindingGeneration
    }

    private func resetToLatestThread() async {
        guard monitoringEnabled else { return }
        let resetStartedAt = Date().timeIntervalSince1970
        guard let source = monitoringDataSource() else {
            snapshot.status = "未找到 Codex 数据目录"
            return
        }
        let generation = sourceGeneration
        let bindingGeneration = sourceBindingGeneration
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        lastLogsSignature = Self.logStoreSignature(logsDB: cachedLogsDatabasePath)

        do {
            let recentThreadsLoader = recentThreadsLoader
            let stateDB = source.stateDatabase.path
            let threads = try await Task.detached(priority: .utility) {
                try recentThreadsLoader(stateDB)
            }.value
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            reconcileThreadOptions(threads)
            lastThreadOptionsSignature = Self.logStoreSignature(logsDB: stateDB)
            lastThreadOptionsRefreshAt = Date().timeIntervalSince1970
            guard let thread = threadOptions.first else {
                snapshot.status = "未找到活动会话"
                return
            }
            let logsDB = cachedLogsDatabasePath
            lastGlobalLogID = try await Task.detached(priority: .utility) {
                try Self.maxGlobalLogID(logsDB: logsDB)
            }.value
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            lastLogsSignature = Self.logStoreSignature(logsDB: logsDB)
            totalRate.clear()
            totalSessionRates.removeAll()
            selectedSmoothedTokensPerSecond = 0
            totalSmoothedTokensPerSecond = 0
            clearStreamState()
            configureTotalSnapshot(source: source)
            await switchToThread(thread.id)
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            await backfillStartupRows(
                source: source,
                logsDB: logsDB,
                since: resetStartedAt - startupBackfillSeconds,
                sourceGeneration: generation,
                sourceBindingGeneration: bindingGeneration
            )
        } catch {
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            snapshot.status = "实时测速不可用：\(error.localizedDescription)"
        }
    }

    private func backfillStartupRows(
        source: CodexDataSource,
        logsDB: String,
        since: TimeInterval,
        sourceGeneration generation: Int,
        sourceBindingGeneration bindingGeneration: Int
    ) async {
        do {
            let reader = logReader(for: logsDB)
            let rows = try await Task.detached(priority: .utility) {
                try reader.globalLogRows(since: since)
            }.value
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            guard !rows.isEmpty else { return }
            for row in rows {
                lastGlobalLogID = max(lastGlobalLogID, row.id)
                _ = add(row: row)
            }
            extendFastPolling(from: Date().timeIntervalSince1970)
            updateSnapshots(now: Date().timeIntervalSince1970)
            lastLogsSignature = Self.logStoreSignature(logsDB: logsDB)
        } catch {
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            snapshot.status = "启动回看日志失败：\(error.localizedDescription)"
        }
    }

    private func switchToThread(_ id: String) async {
        guard let source = monitoringDataSource() else { return }
        let generation = sourceGeneration
        let bindingGeneration = sourceBindingGeneration
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        do {
            let logsDB = cachedLogsDatabasePath
            lastLogID = try await Task.detached(priority: .utility) {
                try Self.maxLogID(logsDB: logsDB, threadID: id)
            }.value
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            threadID = id
            selectedThreadID = id
            selectedRate.clear()
            selectedSmoothedTokensPerSecond = 0
            let option = threadOptions.first { $0.id == id }
            if let option {
                rolloutOffsets[option.rolloutPath] = Self.fileSize(path: option.rolloutPath)
            }
            snapshot.threadID = id
            snapshot.threadTitle = option?.displayTitle ?? "选中会话"
            snapshot.sourceLabel = "\(source.displayPath)/logs_2.sqlite"
            snapshot.status = "监听选中 thread"
            snapshot.updatedAt = Date()
        } catch {
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            snapshot.status = "切换会话失败：\(error.localizedDescription)"
        }
    }

    private func poll() async {
        guard monitoringEnabled else { return }
        guard !pollInProgress else {
            return
        }
        pollInProgress = true
        defer {
            pollInProgress = false
        }

        lastPollProcessedRows = false
        guard monitoringDataSource() != nil else { return }
        let generation = sourceGeneration
        let bindingGeneration = sourceBindingGeneration
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        if threadID.isEmpty {
            await resetToLatestThread()
            return
        }

        do {
            let logsDB = cachedLogsDatabasePath
            let now = Date().timeIntervalSince1970
            if flushExpiredPendingRollouts(now: now) {
                lastPollProcessedRows = true
                extendFastPolling(from: now)
            }
            if refreshLogStoreSignature(logsDB: logsDB) {
                logChangePending = true
            }
            await refreshThreadOptionsIfNeeded(
                source: dataSource,
                now: now,
                generation: generation,
                bindingGeneration: bindingGeneration
            )
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            let hasLogChangeSignal = logChangePending
            let readPlan = LiveRatePollReadPlan(
                now: now,
                hasLogChangeSignal: hasLogChangeSignal,
                fastDisplayWindowActive: now < fastPollUntil,
                activeRollingWindowPresent: hasActiveRollingWindow(now: now),
                lastFallbackPollAt: lastFallbackPollAt,
                lastRolloutReadAt: lastRolloutReadAt,
                idleFallbackPollInterval: idleFallbackPollInterval,
                rolloutFallbackPollInterval: rolloutFallbackPollInterval
            )
            logChangePending = false

            guard readPlan.readsAnyDataSource else {
                updateSnapshots(now: now)
                return
            }
            if readPlan.recordIdleFallbackPollAt {
                lastFallbackPollAt = now
            }

            let globalRows: [LogRow]
            if readPlan.readStreamRows {
                let currentGlobalLogID = lastGlobalLogID
                let reader = logReader(for: logsDB)
                globalRows = try await Task.detached(priority: .utility) {
                    try reader.globalLogRows(afterID: currentGlobalLogID)
                }.value
            } else {
                globalRows = []
            }
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }

            let rolloutReads: [RolloutRead]
            if readPlan.readRolloutUpdates {
                do {
                    rolloutReads = try await loadRolloutUpdates(now: Date().timeIntervalSince1970)
                } catch {
                    guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
                    snapshot.status = "读取会话流失败：\(error.localizedDescription)"
                    return
                }
            } else {
                rolloutReads = []
            }
            _ = applyPollCompletion(
                streamRows: globalRows,
                rolloutReads: rolloutReads,
                sourceGeneration: generation,
                sourceBindingGeneration: bindingGeneration,
                now: Date().timeIntervalSince1970
            )
        } catch {
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            snapshot.status = "读取日志失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func refreshLogStoreSignature(logsDB: String) -> Bool {
        let current = Self.logStoreSignature(logsDB: logsDB)
        defer { lastLogsSignature = current }
        guard let previous = lastLogsSignature,
              current.isPhysicalDatabaseReplacement(comparedTo: previous)
        else {
            return false
        }

        logReader = nil
        lastLogID = 0
        lastGlobalLogID = 0
        selectedRate.clear()
        totalRate.clear()
        totalSessionRates.removeAll()
        selectedSmoothedTokensPerSecond = 0
        totalSmoothedTokensPerSecond = 0
        lastSnapshotPublishAt = 0
        clearStreamState()
        updateSnapshots(now: Date().timeIntervalSince1970)
        return true
    }

    nonisolated static func shouldRefreshThreads(
        current: LogStoreSignature,
        previous: LogStoreSignature?,
        now: TimeInterval,
        lastRefreshAt: TimeInterval,
        ttl: TimeInterval
    ) -> Bool {
        previous != current || now - lastRefreshAt >= ttl
    }

    private func refreshThreadOptionsIfNeeded(
        source: CodexDataSource?,
        now: TimeInterval,
        generation: Int,
        bindingGeneration: Int
    ) async {
        guard let source else { return }
        let stateDB = source.stateDatabase.path
        let signature = Self.logStoreSignature(logsDB: stateDB)
        guard Self.shouldRefreshThreads(
            current: signature,
            previous: lastThreadOptionsSignature,
            now: now,
            lastRefreshAt: lastThreadOptionsRefreshAt,
            ttl: threadOptionsRefreshTTL
        ) else { return }
        lastThreadOptionsSignature = signature
        lastThreadOptionsRefreshAt = now
        do {
            let recentThreadsLoader = recentThreadsLoader
            let threads = try await Task.detached(priority: .utility) {
                try recentThreadsLoader(stateDB)
            }.value
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            reconcileThreadOptions(threads)
        } catch {
            guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return }
            snapshot.status = "刷新活动会话失败：\(error.localizedDescription)"
        }
    }

    private func reconcileThreadOptions(_ threads: [ThreadRow]) {
        var seenThreadIDs = Set<String>()
        let uniqueThreads = threads.filter { seenThreadIDs.insert($0.id).inserted }
        var optionOrder: [String] = []
        var ownerByKey: [String: ThreadRow] = [:]
        for thread in uniqueThreads {
            let option = LiveThreadOption(
                id: thread.id,
                title: thread.title,
                updatedAtMS: thread.updatedAtMS,
                rolloutPath: thread.rolloutPath
            )
            let path = option.normalizedRolloutPath
            let standardized = ThreadRow(
                id: thread.id,
                title: thread.title,
                updatedAtMS: thread.updatedAtMS,
                rolloutPath: path ?? ""
            )
            let key = path.map { "path:\($0)" } ?? "thread:\(thread.id)"
            if let current = ownerByKey[key] {
                if standardized.id == threadID, current.id != threadID {
                    ownerByKey[key] = standardized
                }
            } else {
                optionOrder.append(key)
                ownerByKey[key] = standardized
            }
        }
        let uniqueOwners = optionOrder.compactMap { ownerByKey[$0] }
        var previousOffsets: [String: UInt64] = [:]
        for (path, offset) in rolloutOffsets {
            guard let standardizedPath = LiveThreadOption(
                id: "",
                title: "",
                updatedAtMS: 0,
                rolloutPath: path
            ).normalizedRolloutPath else { continue }
            previousOffsets[standardizedPath] = max(previousOffsets[standardizedPath] ?? 0, offset)
        }
        let options = uniqueOwners.map {
            LiveThreadOption(id: $0.id, title: $0.title, updatedAtMS: $0.updatedAtMS, rolloutPath: $0.rolloutPath)
        }
        threadOptions = options
        rolloutOffsets = Dictionary(uniqueKeysWithValues: options.compactMap { option in
            guard let path = option.normalizedRolloutPath else { return nil }
            return (path, previousOffsets[path] ?? Self.fileSize(path: path))
        })

        if options.contains(where: { $0.id == threadID }) {
            selectedThreadID = threadID
            return
        }
        guard let replacement = options.first else {
            threadID = ""
            selectedThreadID = ""
            lastLogID = 0
            selectedRate.clear()
            selectedSmoothedTokensPerSecond = 0
            snapshot.threadID = ""
            snapshot.threadTitle = "等待会话"
            snapshot.status = "未找到活动会话"
            snapshot.rollingTokensPerSecond = 0
            snapshot.averageTokensPerSecond = 0
            snapshot.outputTokens = 0
            snapshot.outputCharacters = 0
            snapshot.breakdown = LiveTokenBreakdown()
            snapshot.updatedAt = Date()
            return
        }
        threadID = replacement.id
        selectedThreadID = replacement.id
        lastLogID = 0
        selectedRate.clear()
        selectedSmoothedTokensPerSecond = 0
        snapshot.threadID = replacement.id
        snapshot.threadTitle = replacement.displayTitle
    }

    private func loadRolloutUpdates(now: TimeInterval) async throws -> [RolloutRead] {
        guard threadOptions.contains(where: \.hasRolloutPath) else { return [] }
        lastRolloutReadAt = now
        let options = threadOptions
        let offsets = rolloutOffsets
        return try await Task.detached(priority: .utility) {
            try Self.rolloutReads(options: options, offsets: offsets)
        }.value
    }

    @discardableResult
    private func applyPollCompletion(
        streamRows: [LogRow],
        rolloutReads: [RolloutRead],
        sourceGeneration generation: Int,
        sourceBindingGeneration bindingGeneration: Int,
        now: TimeInterval
    ) -> Bool {
        guard isCurrentSource(generation: generation, bindingGeneration: bindingGeneration) else { return false }
        var processedRolloutEvents = flushExpiredPendingRollouts(now: now)
        let processedStreamEvents = processStreamRows(streamRows)
        discardPendingRolloutsMatchedByStream()
        if processRolloutReads(rolloutReads, now: now) {
            processedRolloutEvents = true
        }
        discardPendingRolloutsMatchedByStream()
        if processedStreamEvents || processedRolloutEvents {
            lastPollProcessedRows = true
            extendFastPolling(from: now)
        }
        updateSnapshots(now: now)
        return true
    }

    private func processStreamRows(_ rows: [LogRow]) -> Bool {
        var processedStreamEvents = false
        for row in rows {
            lastGlobalLogID = max(lastGlobalLogID, row.id)
            if add(row: row) {
                processedStreamEvents = true
            }
        }
        return processedStreamEvents
    }

    private func processRolloutReads(_ reads: [RolloutRead], now: TimeInterval) -> Bool {
        var processedEvents = false

        for read in reads {
            rolloutOffsets[read.path] = read.newOffset
            for event in read.events {
                if shouldPendRolloutCompletion(event) {
                    enqueuePendingRollout(event, threadID: read.threadID, now: now)
                } else if publishRolloutEvent(event, threadID: read.threadID) {
                    processedEvents = true
                }
            }
        }

        return processedEvents
    }

    private func shouldPendRolloutCompletion(_ event: RolloutMetricEvent) -> Bool {
        event.category == .visibleText && event.itemID?.isEmpty == false && !event.text.isEmpty
    }

    private func enqueuePendingRollout(_ event: RolloutMetricEvent, threadID: String, now: TimeInterval) {
        guard let itemID = event.itemID else { return }
        let key = Self.visibleMessageIdentity(threadID: threadID, itemID: itemID)
        if pendingRolloutCompletions[key] == nil {
            pendingRolloutOrder.append(key)
        }
        pendingRolloutCompletions[key] = PendingRolloutCompletion(event: event, threadID: threadID, enqueuedAt: now)
        let overflow = pendingRolloutOrder.count - pendingRolloutLimit
        guard overflow > 0 else { return }
        let overflowKeys = Array(pendingRolloutOrder.prefix(overflow))
        pendingRolloutOrder.removeFirst(overflow)
        for overflowKey in overflowKeys {
            if let pending = pendingRolloutCompletions.removeValue(forKey: overflowKey) {
                _ = publishRolloutEvent(pending.event, threadID: pending.threadID)
            }
        }
    }

    private func discardPendingRolloutsMatchedByStream() {
        let matched = pendingRolloutOrder.filter { key in
            guard let pending = pendingRolloutCompletions[key] else { return true }
            return visibleStreamAssemblies.matches(text: pending.event.text, for: key)
        }
        let matchedSet = Set(matched)
        pendingRolloutOrder.removeAll { matchedSet.contains($0) }
        for key in matched {
            pendingRolloutCompletions.removeValue(forKey: key)
        }
    }

    private func flushExpiredPendingRollouts(now: TimeInterval) -> Bool {
        let expired = pendingRolloutOrder.filter { key in
            guard let pending = pendingRolloutCompletions[key] else { return true }
            return now - pending.enqueuedAt >= pendingRolloutWindow
        }
        let expiredSet = Set(expired)
        pendingRolloutOrder.removeAll { expiredSet.contains($0) }
        var published = false
        for key in expired {
            guard let pending = pendingRolloutCompletions.removeValue(forKey: key) else { continue }
            published = publishRolloutEvent(pending.event, threadID: pending.threadID) || published
        }
        return published
    }

    func clearPendingRolloutCompletions() {
        pendingRolloutCompletions.removeAll()
        pendingRolloutOrder.removeAll()
    }

    private func publishRolloutEvent(_ event: RolloutMetricEvent, threadID eventThreadID: String) -> Bool {
        guard shouldCountRolloutEvent(event, threadID: eventThreadID) else { return false }
        add(events: [event], threadID: eventThreadID, keyThreadID: "all", to: &totalRate)
        add(events: [event], threadID: eventThreadID, keyThreadID: eventThreadID, toTotalSessionRateFor: eventThreadID)
        if eventThreadID == threadID {
            add(events: [event], threadID: eventThreadID, keyThreadID: eventThreadID, to: &selectedRate)
        }
        return true
    }

    private func add(row: LogRow) -> Bool {
        updateTraceAttribution(from: row)
        guard let streamEvent = Self.streamEvent(from: row) else { return false }
        updateAttribution(from: streamEvent, row: row)

        var processedEvent = false
        for event in Self.metricEvents(from: streamEvent, row: row, toolNames: itemToolNames) {
            let resolvedThreadID = resolveThreadID(for: event)
            guard shouldCountStreamEvent(event, resolvedThreadID: resolvedThreadID) else { continue }
            if add(event: event, keyThreadID: "all", to: &totalRate) {
                processedEvent = true
            }
            let displayThreadID = resolvedThreadID ?? Self.unattributedDisplaySessionKey(for: event)
            add(event: event, keyThreadID: displayThreadID, toTotalSessionRateFor: displayThreadID)
            if resolvedThreadID == threadID {
                _ = add(event: event, keyThreadID: resolvedThreadID ?? threadID, to: &selectedRate)
            }
        }
        return processedEvent
    }

    private func add(events: [RolloutMetricEvent], threadID: String, keyThreadID: String, to rate: inout RateAccumulator) {
        for event in events {
            let normalized = LiveMetricEvent(
                source: .rollout,
                timestamp: event.timestamp,
                startTimestamp: event.startTimestamp,
                threadID: threadID,
                turnID: event.turnID,
                itemID: event.itemID ?? event.key,
                category: event.category,
                text: event.text,
                exactTokens: event.exactTokens,
                exactOutputTokens: event.exactOutputTokens,
                rollingOnly: event.rollingOnly
            )
            add(event: normalized, keyThreadID: keyThreadID, to: &rate)
        }
    }

    private func add(events: [RolloutMetricEvent], threadID: String, keyThreadID: String, toTotalSessionRateFor displayThreadID: String) {
        for event in events {
            let normalized = LiveMetricEvent(
                source: .rollout,
                timestamp: event.timestamp,
                startTimestamp: event.startTimestamp,
                threadID: threadID,
                turnID: event.turnID,
                itemID: event.itemID ?? event.key,
                category: event.category,
                text: event.text,
                exactTokens: event.exactTokens,
                exactOutputTokens: event.exactOutputTokens,
                rollingOnly: event.rollingOnly
            )
            add(event: normalized, keyThreadID: keyThreadID, toTotalSessionRateFor: displayThreadID)
        }
    }

    private func add(event: LiveMetricEvent, keyThreadID: String, toTotalSessionRateFor displayThreadID: String) {
        var sessionRate = totalSessionRates[displayThreadID] ?? RateAccumulator(resetsOnNewItem: false)
        _ = add(event: event, keyThreadID: keyThreadID, to: &sessionRate)
        totalSessionRates[displayThreadID] = sessionRate
    }

    @discardableResult
    private func add(event: LiveMetricEvent, keyThreadID: String, to rate: inout RateAccumulator) -> Bool {
        guard let category = event.category, category.contributesToLiveRate else { return false }
        let scopedItemID = event.turnID.map { "\($0):\(event.itemID)" } ?? event.itemID
        let key = Self.metricKey(threadID: keyThreadID, itemID: scopedItemID, category: category)
        if event.rollingOnly {
            rate.addRollingOnly(text: event.text, key: key, at: event.timestamp, windowSeconds: windowSeconds, estimator: estimateTokenCount)
            return !event.text.isEmpty
        } else if let exactTokens = event.exactTokens {
            rate.addDistributed(tokens: exactTokens, category: category, key: key, startTimestamp: event.startTimestamp, endingAt: event.timestamp, windowSeconds: windowSeconds)
            return exactTokens > 0
        } else if event.source != .rollout && event.isDelta {
            rate.add(delta: event.text, category: category, key: key, at: event.timestamp, windowSeconds: windowSeconds) { text in
                estimateTokenCount(text, category: category)
            }
            return !event.text.isEmpty
        } else if !event.text.isEmpty {
            rate.addDistributed(text: event.text, category: category, key: key, startTimestamp: event.startTimestamp, endingAt: event.timestamp, windowSeconds: windowSeconds) { text in
                estimateTokenCount(text, category: category)
            }
            return true
        }
        return false
    }

    private func shouldCountStreamEvent(_ event: LiveMetricEvent, resolvedThreadID: String?) -> Bool {
        guard event.source != .rollout,
              let category = event.category,
              !event.text.isEmpty else {
            return true
        }
        let sequence = event.sequenceNumber.map(String.init) ?? "text:\(event.text.hashValue)"
        let resolvedTurnID = event.turnID ?? itemTurnIDs[event.itemID]
        let fingerprint = "\(resolvedThreadID ?? "unknown"):\(resolvedTurnID ?? "unknown"):\(event.itemID):\(category.rawValue):\(sequence)"
        guard countedStreamFingerprints.insertIfNew(fingerprint) else { return false }
        if category == .visibleText,
           let resolvedThreadID,
           !event.itemID.isEmpty,
           event.itemID != "unknown" {
            let identity = Self.visibleMessageIdentity(threadID: resolvedThreadID, itemID: event.itemID)
            visibleStreamAssemblies.append(
                event.text,
                for: identity,
                threadID: resolvedThreadID,
                turnID: resolvedTurnID
            )
        }
        return true
    }

    private func shouldCountRolloutEvent(_ event: RolloutMetricEvent, threadID: String) -> Bool {
        if event.category == .visibleText, !event.text.isEmpty {
            if let itemID = event.itemID,
               !itemID.isEmpty,
               visibleStreamAssemblies.matches(
                   text: event.text,
                   for: Self.visibleMessageIdentity(threadID: threadID, itemID: itemID)
               ) {
                return false
            }
            if event.itemID == nil,
               let turnID = event.turnID,
               visibleStreamAssemblies.contains(
                   text: event.text,
                   threadID: threadID,
                   turnID: turnID
               ) {
                return false
            }
        }
        let timestampBucket = Int((event.timestamp * 1_000).rounded())
        let fingerprint = [
            threadID,
            event.category?.rawValue ?? "none",
            String(timestampBucket),
            String(event.text.hashValue),
            String(event.exactTokens ?? -1),
            String(event.exactOutputTokens ?? -1)
        ].joined(separator: ":")
        guard countedRolloutFingerprints.insertIfNew(fingerprint) else { return false }
        return true
    }

    nonisolated private static func visibleMessageIdentity(threadID: String, itemID: String) -> String {
        "thread:\(threadID)|item:\(itemID)"
    }

    private func updateTraceAttribution(from row: LogRow) {
        let threadFromBody = Self.traceValue(in: row.feedbackLogBody, keys: ["thread.id=", "thread_id=", "conversation.id="])
        let turnFromBody = Self.traceValue(in: row.feedbackLogBody, keys: ["turn.id=", "turn_id="])
        let resolvedThread = row.threadID ?? threadFromBody
        if let resolvedThread, let turnFromBody {
            turnThreadIDs[turnFromBody] = resolvedThread
        }
    }

    private func updateAttribution(from event: ResponseStreamEvent, row: LogRow) {
        let resolvedThread = row.threadID ?? Self.traceValue(in: row.feedbackLogBody, keys: ["thread.id=", "thread_id=", "conversation.id="])
        if let turnID = event.turnID ?? event.item?.metadata?.turnID,
           let resolvedThread {
            turnThreadIDs[turnID] = resolvedThread
        }
        guard let item = event.item else { return }
        if let turnID = item.metadata?.turnID {
            itemTurnIDs[item.id] = turnID
        }
        if let resolvedThread {
            itemThreadIDs[item.id] = resolvedThread
        } else if let turnID = item.metadata?.turnID, let mappedThread = turnThreadIDs[turnID] {
            itemThreadIDs[item.id] = mappedThread
        }
        if let name = item.name {
            itemToolNames[item.id] = name
        }
        if let callID = item.callID {
            itemCallIDs[item.id] = callID
        }
    }

    private func resolveThreadID(for event: LiveMetricEvent) -> String? {
        if let threadID = event.threadID { return threadID }
        if let mapped = itemThreadIDs[event.itemID] { return mapped }
        if let turnID = event.turnID, let mapped = turnThreadIDs[turnID] { return mapped }
        if let turnID = itemTurnIDs[event.itemID], let mapped = turnThreadIDs[turnID] { return mapped }
        return nil
    }

    private func updateSnapshots(now: TimeInterval) {
        selectedRate.prune(now: now, windowSeconds: windowSeconds)
        totalRate.prune(now: now, windowSeconds: windowSeconds)
        for key in Array(totalSessionRates.keys) {
            totalSessionRates[key]?.prune(now: now, windowSeconds: windowSeconds)
            if totalSessionRates[key]?.hasRetainedRollingActivity(now: now, windowSeconds: windowSeconds) != true {
                totalSessionRates.removeValue(forKey: key)
            }
        }

        guard now - lastSnapshotPublishAt >= snapshotPublishInterval || !hasActiveRollingWindow(now: now) else {
            return
        }
        lastSnapshotPublishAt = now

        let selectedHasRecentActivity = selectedRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
        let selectedRawRate = selectedRate.rollingRate(now: now, windowSeconds: windowSeconds, minimumSpan: minimumRateSpanSeconds)
        let selectedDisplayRate = Self.displayRawRate(selectedRawRate, scope: .selectedSession)
        selectedSmoothedTokensPerSecond = Self.smoothedDisplayRate(
            previous: selectedSmoothedTokensPerSecond,
            raw: selectedDisplayRate,
            hasRecentActivity: selectedHasRecentActivity
        )
        if let updated = updatedSnapshot(
            from: snapshot,
            rate: selectedRate,
            now: now,
            rollingTokensPerSecond: selectedSmoothedTokensPerSecond,
            hasRecentActivity: selectedHasRecentActivity,
            emptyStatus: "等待选中会话输出",
            activeStatus: "正在监听选中会话"
        ) {
            snapshot = updated
        }
        let totalHasRecentActivity = totalRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
        let totalSessionRawRates = totalSessionRates.values.map {
            $0.rollingRate(now: now, windowSeconds: windowSeconds, minimumSpan: minimumRateSpanSeconds)
        }
        let totalDisplayRate = Self.combinedAllSessionsDisplayRate(totalSessionRawRates)
        totalSmoothedTokensPerSecond = Self.smoothedDisplayRate(
            previous: totalSmoothedTokensPerSecond,
            raw: totalDisplayRate,
            hasRecentActivity: totalHasRecentActivity
        )
        if let updated = updatedSnapshot(
            from: totalSnapshot,
            rate: totalRate,
            now: now,
            rollingTokensPerSecond: totalSmoothedTokensPerSecond,
            hasRecentActivity: totalHasRecentActivity,
            emptyStatus: "等待任意会话输出",
            activeStatus: "正在汇总全会话输出"
        ) {
            totalSnapshot = updated
        }
    }

    private func updatedSnapshot(
        from snapshot: LiveRateSnapshot,
        rate: RateAccumulator,
        now: TimeInterval,
        rollingTokensPerSecond: Double,
        hasRecentActivity: Bool,
        emptyStatus: String,
        activeStatus: String
    ) -> LiveRateSnapshot? {
        let averageTokensPerSecond = rate.averageRate
        let outputTokens = rate.outputTokens
        let outputCharacters = rate.outputCharacters
        let breakdown = rate.breakdown
        let status = rate.outputTokens > 0 || hasRecentActivity ? activeStatus : emptyStatus

        var updated = snapshot
        updated.rollingTokensPerSecond = rollingTokensPerSecond
        updated.averageTokensPerSecond = averageTokensPerSecond
        updated.outputTokens = outputTokens
        updated.outputCharacters = outputCharacters
        updated.breakdown = breakdown
        updated.status = status

        guard Self.displayBucket(snapshot.rollingTokensPerSecond) != Self.displayBucket(updated.rollingTokensPerSecond)
            || Self.displayBucket(snapshot.averageTokensPerSecond) != Self.displayBucket(updated.averageTokensPerSecond)
            || snapshot.outputTokens != updated.outputTokens
            || snapshot.outputCharacters != updated.outputCharacters
            || snapshot.breakdown != updated.breakdown
            || snapshot.status != updated.status else {
            return nil
        }

        updated.updatedAt = Date()
        return updated
    }

    nonisolated static func smoothedDisplayRate(previous: Double, raw: Double, hasRecentActivity: Bool) -> Double {
        guard raw.isFinite else { return max(0, previous) }
        let clampedRaw = max(0, raw)
        guard hasRecentActivity, clampedRaw >= 0.05 else { return 0 }
        let alpha = clampedRaw >= previous ? 0.28 : 0.18
        return max(0, previous + (clampedRaw - previous) * alpha)
    }

    nonisolated static func displayRawRate(_ raw: Double, scope: DisplayRateScope) -> Double {
        guard raw.isFinite else { return 0 }
        let clampedRaw = max(0, raw)
        switch scope {
        case .selectedSession:
            return min(clampedRaw, selectedSessionDisplayRateCap)
        case .allSessions:
            return clampedRaw
        }
    }

    nonisolated static func combinedAllSessionsDisplayRate(_ rawRates: [Double]) -> Double {
        rawRates.reduce(0) { total, raw in
            total + displayRawRate(raw, scope: .selectedSession)
        }
    }

    nonisolated static func unattributedDisplaySessionKey(for event: LiveMetricEvent) -> String {
        if let threadID = event.threadID, !threadID.isEmpty { return threadID }
        return unattributedLiveRateSessionKey
    }

    nonisolated static func displayBucket(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        if value < 10 {
            return Int((value * 10).rounded(.toNearestOrAwayFromZero))
        }
        return 10_000 + Int(value.rounded(.toNearestOrAwayFromZero))
    }

    private func configureTotalSnapshot(source: CodexDataSource) {
        let interfaceLabel = totalSnapshot.interfaceLabel
        totalSnapshot = LiveRateSnapshot(
            threadID: "all",
            threadTitle: "全会话输出汇总",
            sourceLabel: "\(source.displayPath)/logs_2.sqlite",
            status: "等待任意会话输出",
            scopeLabel: "全会话",
            interfaceLabel: interfaceLabel
        )
        updateTokenCountingLabel()
    }

    private func disableMonitoringSnapshots() {
        let disabledAt = Date()
        snapshot.rollingTokensPerSecond = 0
        snapshot.averageTokensPerSecond = 0
        snapshot.outputTokens = 0
        snapshot.outputCharacters = 0
        snapshot.breakdown = LiveTokenBreakdown()
        snapshot.status = "实时速率已关闭"
        snapshot.updatedAt = disabledAt

        totalSnapshot.rollingTokensPerSecond = 0
        totalSnapshot.averageTokensPerSecond = 0
        totalSnapshot.outputTokens = 0
        totalSnapshot.outputCharacters = 0
        totalSnapshot.breakdown = LiveTokenBreakdown()
        totalSnapshot.status = "实时速率已关闭"
        totalSnapshot.updatedAt = disabledAt
    }


}


#if DEBUG
extension LiveRateMonitor {
    func testPrepareForLiveRateProcessing(
        selectedThreadID id: String,
        threadOptions options: [LiveThreadOption] = []
    ) {
        threadID = id
        selectedThreadID = id
        threadOptions = options
        snapshot.threadID = id
        snapshot.threadTitle = "Test selected"
        totalSnapshot.threadID = "all"
        totalSnapshot.threadTitle = "全会话输出汇总"
        selectedRate.clear()
        totalRate.clear()
        totalSessionRates.removeAll()
        selectedSmoothedTokensPerSecond = 0
        totalSmoothedTokensPerSecond = 0
        clearStreamState()
    }

    func testProcessPollInputs(
        streamRows: [LogRow],
        rolloutReads: [RolloutRead],
        now: TimeInterval
    ) {
        _ = applyPollCompletion(
            streamRows: streamRows,
            rolloutReads: rolloutReads,
            sourceGeneration: sourceGeneration,
            sourceBindingGeneration: sourceBindingGeneration,
            now: now
        )
    }

    var testSourceGeneration: Int {
        sourceGeneration
    }

    var testSourceBindingGeneration: Int {
        sourceBindingGeneration
    }

    @discardableResult
    func testApplyPollCompletion(
        streamRows: [LogRow],
        rolloutReads: [RolloutRead],
        sourceGeneration: Int,
        sourceBindingGeneration: Int,
        now: TimeInterval
    ) -> Bool {
        applyPollCompletion(
            streamRows: streamRows,
            rolloutReads: rolloutReads,
            sourceGeneration: sourceGeneration,
            sourceBindingGeneration: sourceBindingGeneration,
            now: now
        )
    }

    func testRefreshSnapshots(now: TimeInterval) {
        updateSnapshots(now: now)
    }

    var testTotalSessionRateKeys: [String] {
        totalSessionRates.keys.sorted()
    }

    var testVisibleAssemblyCount: Int {
        visibleStreamAssemblies.count
    }

    var testPendingRolloutCount: Int {
        pendingRolloutCompletions.count
    }

    func testAcceptedRolloutEventCount(_ events: [RolloutMetricEvent], threadID: String) -> Int {
        events.filter { shouldCountRolloutEvent($0, threadID: threadID) }.count
    }

    nonisolated static func testMaxLogID(logsDB: String, threadID: String) throws -> Int {
        try maxLogID(logsDB: logsDB, threadID: threadID)
    }

    nonisolated static func testLogRows(logsDB: String, threadID: String, afterID: Int) throws -> [LogRow] {
        try logRows(logsDB: logsDB, threadID: threadID, afterID: afterID)
    }

    func testPrimeLogStore(logsDB: String, lastGlobalLogID: Int) {
        lastLogsSignature = Self.logStoreSignature(logsDB: logsDB)
        self.lastGlobalLogID = lastGlobalLogID
    }

    func testReadGlobalRows(logsDB: String) throws -> [LogRow] {
        try logReader(for: logsDB).globalLogRows(afterID: lastGlobalLogID)
    }

    @discardableResult
    func testRefreshLogStoreSignature(logsDB: String) -> Bool {
        refreshLogStoreSignature(logsDB: logsDB)
    }

    func testSetRolloutOffset(_ offset: UInt64, path: String) {
        rolloutOffsets[path] = offset
    }

    func testRolloutOffset(path: String) -> UInt64? {
        rolloutOffsets[path]
    }

    func testReconcileThreadOptions(_ threads: [ThreadRow]) {
        reconcileThreadOptions(threads)
    }

    var testRolloutPathCount: Int {
        rolloutOffsets.count
    }

    func testRefreshThreadOptionsIfNeeded(now: TimeInterval) async {
        await refreshThreadOptionsIfNeeded(
            source: dataSource,
            now: now,
            generation: sourceGeneration,
            bindingGeneration: sourceBindingGeneration
        )
    }
}
#endif

extension CodexDataSource {
    var logsDatabase: URL {
        codexHome.appendingPathComponent("logs_2.sqlite")
    }
}
