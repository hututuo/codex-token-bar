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
    var dataSource: CodexDataSource?
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
    var tokenEncoder: CoreBpe?

    struct LogStoreSignature: Equatable {
        let databaseSize: UInt64
        let databaseModifiedAt: TimeInterval
        let walSize: UInt64
        let walModifiedAt: TimeInterval
    }

    init(
        preciseTokenCountingEnabled: Bool = LiveRateMonitor.defaultPreciseTokenCountingEnabled(),
        monitoringEnabled: Bool = LiveRateMonitor.defaultMonitoringEnabled(),
        logReaderFactory: LiveRateLogReaderMaking = DefaultLiveRateLogReaderFactory()
    ) {
        self.preciseTokenCountingEnabled = preciseTokenCountingEnabled
        self.monitoringEnabled = monitoringEnabled
        self.logReaderFactory = logReaderFactory
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

    private func resetToLatestThread() async {
        guard monitoringEnabled else { return }
        let resetStartedAt = Date().timeIntervalSince1970
        guard let source = resolver.resolve() else {
            snapshot.status = "未找到 Codex 数据目录"
            return
        }
        setDataSource(source)
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        lastLogsSignature = Self.logStoreSignature(logsDB: cachedLogsDatabasePath)

        do {
            let stateDB = source.stateDatabase.path
            let threads = try await Task.detached(priority: .utility) {
                try Self.recentThreads(stateDB: stateDB)
            }.value
            threadOptions = threads.map {
                LiveThreadOption(id: $0.id, title: $0.title, updatedAtMS: $0.updatedAtMS, rolloutPath: $0.rolloutPath)
            }
            guard let thread = threads.first else {
                snapshot.status = "未找到活动会话"
                return
            }
            let logsDB = cachedLogsDatabasePath
            lastGlobalLogID = try await Task.detached(priority: .utility) {
                try Self.maxGlobalLogID(logsDB: logsDB)
            }.value
            lastLogsSignature = Self.logStoreSignature(logsDB: logsDB)
            totalRate.clear()
            totalSessionRates.removeAll()
            selectedSmoothedTokensPerSecond = 0
            totalSmoothedTokensPerSecond = 0
            clearStreamState()
            rolloutOffsets = Dictionary(
                uniqueKeysWithValues: threads.map { ($0.rolloutPath, Self.fileSize(path: $0.rolloutPath)) }
            )
            configureTotalSnapshot(source: source)
            await switchToThread(thread.id)
            await backfillStartupRows(source: source, logsDB: logsDB, since: resetStartedAt - startupBackfillSeconds)
        } catch {
            snapshot.status = "实时测速不可用：\(error.localizedDescription)"
        }
    }

    private func backfillStartupRows(source: CodexDataSource, logsDB: String, since: TimeInterval) async {
        do {
            let reader = logReader(for: logsDB)
            let rows = try await Task.detached(priority: .utility) {
                try reader.globalLogRows(since: since)
            }.value
            guard !rows.isEmpty else { return }
            for row in rows {
                lastGlobalLogID = max(lastGlobalLogID, row.id)
                _ = add(row: row)
            }
            extendFastPolling(from: Date().timeIntervalSince1970)
            updateSnapshots(now: Date().timeIntervalSince1970)
            lastLogsSignature = Self.logStoreSignature(logsDB: logsDB)
        } catch {
            snapshot.status = "启动回看日志失败：\(error.localizedDescription)"
        }
    }

    private func switchToThread(_ id: String) async {
        guard let source = dataSource ?? resolver.resolve() else { return }
        setDataSource(source)
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        do {
            let logsDB = cachedLogsDatabasePath
            lastLogID = try await Task.detached(priority: .utility) {
                try Self.maxLogID(logsDB: logsDB, threadID: id)
            }.value
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
        guard let source = dataSource ?? resolver.resolve() else { return }
        setDataSource(source)
        configureLogWatcher(logsDirectory: cachedLogsDirectoryPath)
        if threadID.isEmpty {
            await resetToLatestThread()
            return
        }

        do {
            let logsDB = cachedLogsDatabasePath
            let now = Date().timeIntervalSince1970
            let hasLogChangeSignal = logChangePending
            let shouldPollLogs = hasLogChangeSignal || now - lastFallbackPollAt >= idleFallbackPollInterval
            let shouldReadRollout = hasLogChangeSignal || now - lastRolloutReadAt >= rolloutFallbackPollInterval
            logChangePending = false

            guard shouldPollLogs || shouldReadRollout else {
                updateSnapshots(now: now)
                return
            }
            if shouldPollLogs && !hasLogChangeSignal {
                lastFallbackPollAt = now
            }

            let globalRows: [LogRow]
            if shouldPollLogs {
                let currentGlobalLogID = lastGlobalLogID
                let reader = logReader(for: logsDB)
                globalRows = try await Task.detached(priority: .utility) {
                    try reader.globalLogRows(afterID: currentGlobalLogID)
                }.value
            } else {
                globalRows = []
            }

            guard !globalRows.isEmpty else {
                let processedRolloutEvents = shouldReadRollout ? await readRolloutUpdates(now: now) : false
                if !processedRolloutEvents {
                    updateSnapshots(now: now)
                }
                return
            }
            lastPollProcessedRows = true
            extendFastPolling(from: Date().timeIntervalSince1970)

            var processedStreamEvents = false
            for row in globalRows {
                lastGlobalLogID = max(lastGlobalLogID, row.id)
                if add(row: row) {
                    processedStreamEvents = true
                }
            }

            if !processedStreamEvents {
                let processedRolloutEvents = shouldReadRollout ? await readRolloutUpdates(now: Date().timeIntervalSince1970) : false
                if !processedRolloutEvents {
                    updateSnapshots(now: Date().timeIntervalSince1970)
                }
            } else {
                updateSnapshots(now: Date().timeIntervalSince1970)
            }
        } catch {
            snapshot.status = "读取日志失败：\(error.localizedDescription)"
        }
    }

    private func readRolloutUpdates(now: TimeInterval) async -> Bool {
        guard !threadOptions.isEmpty else { return false }
        lastRolloutReadAt = now
        let options = threadOptions
        let offsets = rolloutOffsets

        do {
            let reads = try await Task.detached(priority: .utility) {
                try Self.rolloutReads(options: options, offsets: offsets)
            }.value
            var processedEvents = false

            for read in reads {
                rolloutOffsets[read.path] = read.newOffset
                let events = read.events.filter { shouldCountRolloutEvent($0, threadID: read.threadID) }
                guard !events.isEmpty else { continue }
                processedEvents = true
                add(events: events, threadID: read.threadID, keyThreadID: "all", to: &totalRate)
                add(events: events, threadID: read.threadID, keyThreadID: read.threadID, toTotalSessionRateFor: read.threadID)
                if read.threadID == threadID {
                    add(events: events, threadID: read.threadID, keyThreadID: read.threadID, to: &selectedRate)
                }
            }

            guard processedEvents else { return false }
            lastPollProcessedRows = true
            extendFastPolling(from: now)
            updateSnapshots(now: Date().timeIntervalSince1970)
            return true
        } catch {
            snapshot.status = "读取会话流失败：\(error.localizedDescription)"
            return false
        }
    }

    private func add(row: LogRow) -> Bool {
        updateTraceAttribution(from: row)
        guard let streamEvent = Self.streamEvent(from: row) else { return false }
        updateAttribution(from: streamEvent, row: row)

        var processedEvent = false
        for event in Self.metricEvents(from: streamEvent, row: row, toolNames: itemToolNames) {
            guard shouldCountStreamEvent(event) else { continue }
            let resolvedThreadID = resolveThreadID(for: event)
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
                itemID: event.key,
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
                itemID: event.key,
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
        let key = Self.metricKey(threadID: keyThreadID, itemID: event.itemID, category: category)
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

    private func shouldCountStreamEvent(_ event: LiveMetricEvent) -> Bool {
        guard event.source != .rollout,
              let category = event.category,
              !event.text.isEmpty else {
            return true
        }
        let sequence = event.sequenceNumber.map(String.init) ?? "text:\(event.text.hashValue)"
        let fingerprint = "\(event.itemID):\(category.rawValue):\(sequence)"
        return countedStreamFingerprints.insertIfNew(fingerprint)
    }

    private func shouldCountRolloutEvent(_ event: RolloutMetricEvent, threadID: String) -> Bool {
        let timestampBucket = Int((event.timestamp * 1_000).rounded())
        let fingerprint = [
            threadID,
            event.category?.rawValue ?? "none",
            String(timestampBucket),
            String(event.text.hashValue),
            String(event.exactTokens ?? -1),
            String(event.exactOutputTokens ?? -1)
        ].joined(separator: ":")
        return countedRolloutFingerprints.insertIfNew(fingerprint)
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
        if let turnID = event.item?.metadata?.turnID,
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
        for key in totalSessionRates.keys {
            totalSessionRates[key]?.prune(now: now, windowSeconds: windowSeconds)
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
        if let turnID = event.turnID, !turnID.isEmpty { return "turn:\(turnID)" }
        if let callID = event.callID, !callID.isEmpty { return "call:\(callID)" }
        return "item:\(event.itemID)"
    }

    nonisolated static func displayBucket(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        if value < 10 {
            return Int((value * 10).rounded(.toNearestOrAwayFromZero))
        }
        return 10_000 + Int(value.rounded(.toNearestOrAwayFromZero))
    }

    private func configureTotalSnapshot(source: CodexDataSource) {
        totalSnapshot.threadID = "all"
        totalSnapshot.threadTitle = "全会话输出汇总"
        totalSnapshot.sourceLabel = "\(source.displayPath)/logs_2.sqlite"
        totalSnapshot.scopeLabel = "全会话"
        updateTokenCountingLabel()
        totalSnapshot.status = "等待任意会话输出"
        totalSnapshot.updatedAt = Date()
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
    nonisolated static func testMaxLogID(logsDB: String, threadID: String) throws -> Int {
        try maxLogID(logsDB: logsDB, threadID: threadID)
    }

    nonisolated static func testLogRows(logsDB: String, threadID: String, afterID: Int) throws -> [LogRow] {
        try logRows(logsDB: logsDB, threadID: threadID, afterID: afterID)
    }
}
#endif

extension CodexDataSource {
    var logsDatabase: URL {
        codexHome.appendingPathComponent("logs_2.sqlite")
    }
}
