import Foundation
import Darwin
import SwiftUI
import TiktokenSwift

@MainActor
final class LiveRateMonitor: ObservableObject {
    @Published var snapshot = LiveRateSnapshot()
    @Published var totalSnapshot = LiveRateSnapshot(
        threadTitle: "全会话输出汇总",
        status: "等待任意会话输出",
        scopeLabel: "全会话"
    )
    @Published private(set) var threadOptions: [LiveThreadOption] = []
    @Published private(set) var selectedThreadID = ""
    @Published private(set) var preciseTokenCountingEnabled: Bool

    private let resolver = CodexDataSourceResolver()
    let logReaderFactory: LiveRateLogReaderMaking
    var dataSource: CodexDataSource?
    let windowSeconds: TimeInterval = 2.5
    private let fastPollInterval: TimeInterval = 0.25
    private let idlePollInterval: TimeInterval = 1.0
    private let idleFallbackPollInterval: TimeInterval = 2.0
    let activeFastPollHoldSeconds: TimeInterval = 10.0
    private let snapshotPublishInterval: TimeInterval = 0.25
    private let startupBackfillSeconds: TimeInterval = 4.0
    private let minimumRateSpanSeconds: TimeInterval = 0.4
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
    private var pollInProgress = false
    var logReader: LiveRateLogReading?
    var selectedRate = RateAccumulator(resetsOnNewItem: false)
    var totalRate = RateAccumulator(resetsOnNewItem: false)
    private var rolloutOffsets: [String: UInt64] = [:]
    var turnThreadIDs: [String: String] = [:]
    var itemTurnIDs: [String: String] = [:]
    var itemThreadIDs: [String: String] = [:]
    var itemToolNames: [String: String] = [:]
    var itemCallIDs: [String: String] = [:]
    var countedStreamFingerprints = RecentFingerprintSet(limit: 4_096)
    var tokenEncoder: CoreBpe?

    struct LogStoreSignature: Equatable {
        let databaseSize: UInt64
        let databaseModifiedAt: TimeInterval
        let walSize: UInt64
        let walModifiedAt: TimeInterval
    }

    init(
        preciseTokenCountingEnabled: Bool = LiveRateMonitor.defaultPreciseTokenCountingEnabled(),
        logReaderFactory: LiveRateLogReaderMaking = DefaultLiveRateLogReaderFactory()
    ) {
        self.preciseTokenCountingEnabled = preciseTokenCountingEnabled
        self.logReaderFactory = logReaderFactory
        Task {
            updateTokenCountingLabel()
            start()
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

    func start() {
        timer?.invalidate()
        scheduleNextPoll(after: 0.02)
    }

    func scheduleNextPoll(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
        if enabled {
            Task { await warmTokenEncoder() }
        } else {
            tokenEncoder = nil
            updateTokenCountingLabel()
        }
    }

    private func resetToLatestThread() async {
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
                add(row: row)
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
            let shouldPollLogs = logChangePending
                || now < fastPollUntil
                || hasActiveRollingWindow(now: now)
                || now - lastFallbackPollAt >= idleFallbackPollInterval
            logChangePending = false

            guard shouldPollLogs else {
                updateSnapshots(now: now)
                return
            }
            if now >= fastPollUntil {
                lastFallbackPollAt = now
            }

            let currentGlobalLogID = lastGlobalLogID
            let reader = logReader(for: logsDB)
            let globalRows = try await Task.detached(priority: .utility) {
                try reader.globalLogRows(afterID: currentGlobalLogID)
            }.value

            guard !globalRows.isEmpty else {
                updateSnapshots(now: now)
                return
            }
            lastPollProcessedRows = true
            extendFastPolling(from: Date().timeIntervalSince1970)

            for row in globalRows {
                lastGlobalLogID = max(lastGlobalLogID, row.id)
                add(row: row)
            }

            updateSnapshots(now: Date().timeIntervalSince1970)
        } catch {
            snapshot.status = "读取日志失败：\(error.localizedDescription)"
        }
    }

    private func add(row: LogRow) {
        updateTraceAttribution(from: row)
        guard let streamEvent = Self.streamEvent(from: row) else { return }
        updateAttribution(from: streamEvent, row: row)

        for event in Self.metricEvents(from: streamEvent, row: row, toolNames: itemToolNames) {
            guard shouldCountStreamEvent(event) else { continue }
            let resolvedThreadID = resolveThreadID(for: event)
            add(event: event, keyThreadID: "all", to: &totalRate)
            if resolvedThreadID == threadID {
                add(event: event, keyThreadID: resolvedThreadID ?? threadID, to: &selectedRate)
            }
        }
    }

    private func add(events: [RolloutMetricEvent], threadID: String, to rate: inout RateAccumulator) {
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
            add(event: normalized, keyThreadID: threadID, to: &rate)
        }
    }

    private func add(event: LiveMetricEvent, keyThreadID: String, to rate: inout RateAccumulator) {
        if let exactOutputTokens = event.exactOutputTokens, exactOutputTokens > 0 {
            rate.addExactModelOutput(exactOutputTokens)
        }
        guard let category = event.category else { return }
        let key = Self.metricKey(threadID: keyThreadID, itemID: event.itemID, category: category)
        if event.rollingOnly {
            rate.addRollingOnly(text: event.text, key: key, at: event.timestamp, windowSeconds: windowSeconds, estimator: estimateTokenCount)
        } else if let exactTokens = event.exactTokens {
            rate.addDistributed(tokens: exactTokens, category: category, key: key, startTimestamp: event.startTimestamp, endingAt: event.timestamp, windowSeconds: windowSeconds)
        } else if (event.source == .sse || event.source == .websocket) && event.isDelta {
            rate.add(delta: event.text, category: category, key: key, at: event.timestamp, windowSeconds: windowSeconds) { text in
                estimateTokenCount(text, category: category)
            }
        } else if !event.text.isEmpty {
            rate.addDistributed(text: event.text, category: category, key: key, startTimestamp: event.startTimestamp, endingAt: event.timestamp, windowSeconds: windowSeconds) { text in
                estimateTokenCount(text, category: category)
            }
        }
    }

    private func shouldCountStreamEvent(_ event: LiveMetricEvent) -> Bool {
        guard event.source == .sse || event.source == .websocket,
              let category = event.category,
              !event.text.isEmpty else {
            return true
        }
        let sequence = event.sequenceNumber.map(String.init) ?? "\(event.timestamp):\(event.text.hashValue)"
        let fingerprint = "\(event.itemID):\(category.rawValue):\(sequence)"
        return countedStreamFingerprints.insertIfNew(fingerprint)
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

        guard now - lastSnapshotPublishAt >= snapshotPublishInterval || !hasActiveRollingWindow(now: now) else {
            return
        }
        lastSnapshotPublishAt = now

        if let updated = updatedSnapshot(from: snapshot, rate: selectedRate, now: now, emptyStatus: "等待选中会话输出", activeStatus: "正在监听选中会话") {
            snapshot = updated
        }
        if let updated = updatedSnapshot(from: totalSnapshot, rate: totalRate, now: now, emptyStatus: "等待任意会话输出", activeStatus: "正在汇总全会话输出") {
            totalSnapshot = updated
        }
    }

    private func updatedSnapshot(
        from snapshot: LiveRateSnapshot,
        rate: RateAccumulator,
        now: TimeInterval,
        emptyStatus: String,
        activeStatus: String
    ) -> LiveRateSnapshot? {
        let rollingTokensPerSecond = rate.rollingRate(now: now, windowSeconds: windowSeconds, minimumSpan: minimumRateSpanSeconds)
        let averageTokensPerSecond = rate.averageRate
        let outputTokens = rate.outputTokens
        let outputCharacters = rate.outputCharacters
        let breakdown = rate.breakdown
        let status = rate.outputTokens > 0 || rate.hasRecentActivity(now: now, windowSeconds: windowSeconds) ? activeStatus : emptyStatus

        var updated = snapshot
        updated.rollingTokensPerSecond = rollingTokensPerSecond
        updated.averageTokensPerSecond = averageTokensPerSecond
        updated.outputTokens = outputTokens
        updated.outputCharacters = outputCharacters
        updated.breakdown = breakdown
        updated.status = status

        guard Self.displayTenths(snapshot.rollingTokensPerSecond) != Self.displayTenths(updated.rollingTokensPerSecond)
            || Self.displayTenths(snapshot.averageTokensPerSecond) != Self.displayTenths(updated.averageTokensPerSecond)
            || snapshot.outputTokens != updated.outputTokens
            || snapshot.outputCharacters != updated.outputCharacters
            || snapshot.breakdown != updated.breakdown
            || snapshot.status != updated.status else {
            return nil
        }

        updated.updatedAt = Date()
        return updated
    }

    nonisolated private static func displayTenths(_ value: Double) -> Int {
        Int((value * 10).rounded(.toNearestOrAwayFromZero))
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
