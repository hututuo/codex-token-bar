import Foundation
import Darwin
import SwiftUI
import TiktokenSwift

@MainActor
final class LiveRateMonitor: ObservableObject {
    @Published private(set) var snapshot = LiveRateSnapshot()
    @Published private(set) var totalSnapshot = LiveRateSnapshot(
        threadTitle: "全会话输出汇总",
        status: "等待任意会话输出",
        scopeLabel: "全会话"
    )
    @Published private(set) var threadOptions: [LiveThreadOption] = []
    @Published private(set) var selectedThreadID = ""
    @Published private(set) var preciseTokenCountingEnabled: Bool

    private let resolver = CodexDataSourceResolver()
    private var dataSource: CodexDataSource?
    private let windowSeconds: TimeInterval = 2.5
    private let fastPollInterval: TimeInterval = 0.25
    private let idlePollInterval: TimeInterval = 1.0
    private let idleFallbackPollInterval: TimeInterval = 2.0
    private let activeFastPollHoldSeconds: TimeInterval = 10.0
    private let snapshotPublishInterval: TimeInterval = 0.25
    private let startupBackfillSeconds: TimeInterval = 4.0
    private let minimumRateSpanSeconds: TimeInterval = 0.4
    private var timer: Timer?
    private var logsDirectorySource: DispatchSourceFileSystemObject?
    private var watchedLogsDirectory = ""
    private var cachedLogsDatabasePath = ""
    private var cachedLogsDirectoryPath = ""
    private var logChangePending = false
    private var fastPollUntil: TimeInterval = 0
    private var threadID = ""
    private var lastLogID = 0
    private var lastGlobalLogID = 0
    private var lastLogsSignature: LogStoreSignature?
    private var lastPollProcessedRows = false
    private var lastSnapshotPublishAt: TimeInterval = 0
    private var lastFallbackPollAt: TimeInterval = 0
    private var pollInProgress = false
    private var logReader: LiveRateLogDatabaseReader?
    private var selectedRate = RateAccumulator(resetsOnNewItem: false)
    private var totalRate = RateAccumulator(resetsOnNewItem: false)
    private var rolloutOffsets: [String: UInt64] = [:]
    private var turnThreadIDs: [String: String] = [:]
    private var itemTurnIDs: [String: String] = [:]
    private var itemThreadIDs: [String: String] = [:]
    private var itemToolNames: [String: String] = [:]
    private var itemCallIDs: [String: String] = [:]
    private var countedStreamFingerprints: Set<String> = []
    private var tokenEncoder: CoreBpe?

    private struct LogStoreSignature: Equatable {
        let databaseSize: UInt64
        let databaseModifiedAt: TimeInterval
        let walSize: UInt64
        let walModifiedAt: TimeInterval
    }

    init(preciseTokenCountingEnabled: Bool = LiveRateMonitor.defaultPreciseTokenCountingEnabled()) {
        self.preciseTokenCountingEnabled = preciseTokenCountingEnabled
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

    private func scheduleNextPoll(after interval: TimeInterval) {
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

    private func setDataSource(_ source: CodexDataSource) {
        guard dataSource != source || cachedLogsDatabasePath.isEmpty || cachedLogsDirectoryPath.isEmpty else {
            return
        }
        dataSource = source
        let homePath = source.codexHome.path as NSString
        cachedLogsDatabasePath = homePath.appendingPathComponent("logs_2.sqlite")
        cachedLogsDirectoryPath = (cachedLogsDatabasePath as NSString).deletingLastPathComponent
    }

    private func configureLogWatcher(logsDirectory directory: String) {
        guard !directory.isEmpty, watchedLogsDirectory != directory else { return }

        logsDirectorySource?.cancel()
        logsDirectorySource = nil
        watchedLogsDirectory = directory

        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let eventSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        eventSource.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logChangePending = true
                self.extendFastPolling(from: Date().timeIntervalSince1970)
                self.scheduleNextPoll(after: 0.02)
            }
        }
        eventSource.setCancelHandler {
            close(descriptor)
        }
        logsDirectorySource = eventSource
        eventSource.resume()
    }

    private func logReader(for logsDB: String) -> LiveRateLogDatabaseReader {
        if let logReader, logReader.path == logsDB {
            return logReader
        }
        let reader = LiveRateLogDatabaseReader(path: logsDB)
        logReader = reader
        return reader
    }

    private func hasActiveRollingWindow(now: TimeInterval) -> Bool {
        selectedRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
            || totalRate.hasRecentActivity(now: now, windowSeconds: windowSeconds)
    }

    private func extendFastPolling(from now: TimeInterval) {
        fastPollUntil = max(fastPollUntil, now + activeFastPollHoldSeconds)
    }

    private func clearStreamState() {
        turnThreadIDs.removeAll()
        itemTurnIDs.removeAll()
        itemThreadIDs.removeAll()
        itemToolNames.removeAll()
        itemCallIDs.removeAll()
        countedStreamFingerprints.removeAll()
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
        if countedStreamFingerprints.contains(fingerprint) {
            return false
        }
        countedStreamFingerprints.insert(fingerprint)
        return true
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

    private func warmTokenEncoder() async {
        do {
            tokenEncoder = try await Task.detached(priority: .utility) {
                try await CoreBpe.o200kBase()
            }.value
        } catch {
            tokenEncoder = nil
        }
        updateTokenCountingLabel()
    }

    private func updateTokenCountingLabel() {
        let label = preciseTokenCountingEnabled && tokenEncoder != nil ? "stream deltas + o200k" : "stream deltas + calibrated"
        snapshot.interfaceLabel = label
        totalSnapshot.interfaceLabel = label
    }

    private func estimateTokenCount(_ text: String) -> Int {
        estimateTokenCount(text, category: .visibleText)
    }

    private func estimateTokenCount(_ text: String, category: LiveTokenCategory) -> Int {
        if preciseTokenCountingEnabled, let tokenEncoder, text.count <= 16_384 {
            return tokenEncoder.encodeOrdinary(text: text).count
        }

        var tokens = 0.0
        var asciiRun = 0
        let asciiDivisor = category == .visibleText ? 4.2 : 3.0

        func flushASCII() {
            guard asciiRun > 0 else { return }
            tokens += max(1.0, Double(asciiRun) / asciiDivisor)
            asciiRun = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.value < 128, !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                asciiRun += 1
            } else {
                flushASCII()
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    tokens += Self.nonASCIITokenWeight(scalar, category: category)
                }
            }
        }
        flushASCII()
        return Int(tokens.rounded(.toNearestOrAwayFromZero))
    }

    nonisolated private static func nonASCIITokenWeight(_ scalar: UnicodeScalar, category: LiveTokenCategory) -> Double {
        if isCJK(scalar) {
            return category == .visibleText ? 0.58 : 0.8
        }
        if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
            return category == .visibleText ? 0.35 : 0.7
        }
        return category == .visibleText ? 0.8 : 1.0
    }

    nonisolated private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF:
            return true
        default:
            return false
        }
    }

    nonisolated private static func metricKey(threadID: String, itemID: String, category: LiveTokenCategory) -> String {
        "\(threadID):\(itemID):\(category.rawValue)"
    }
}

private extension LiveRateMonitor {
    nonisolated static func recentThreads(stateDB: String) throws -> [ThreadRow] {
        let sql = """
        SELECT id, title, rollout_path, coalesce(updated_at_ms, updated_at * 1000) AS updated_at_ms
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at_ms DESC, updated_at DESC
        LIMIT 20;
        """
        return try sqliteRows(db: stateDB, sql: sql) { statement in
            ThreadRow(
                id: sqliteText(statement, 0) ?? "",
                title: sqliteText(statement, 1) ?? "",
                updatedAtMS: sqliteInt(statement, 3),
                rolloutPath: sqliteText(statement, 2) ?? ""
            )
        }
    }

    nonisolated static func maxLogID(logsDB: String, threadID: String) throws -> Int {
        let sql = "SELECT coalesce(max(id), 0) AS maxID FROM logs WHERE thread_id = '\(sqlEscape(threadID))';"
        return try sqliteScalarInt(db: logsDB, sql: sql)
    }

    nonisolated static func maxGlobalLogID(logsDB: String) throws -> Int {
        let sql = "SELECT coalesce(max(id), 0) AS maxID FROM logs;"
        return try sqliteScalarInt(db: logsDB, sql: sql)
    }

    nonisolated static func logRows(logsDB: String, threadID: String, afterID: Int) throws -> [LogRow] {
        let sql = """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE thread_id = '\(sqlEscape(threadID))'
          AND id > \(afterID)
          AND target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket event:%'
        ORDER BY id ASC
        LIMIT 500;
        """
        return try sqliteRows(db: logsDB, sql: sql) { statement in
            LogRow(
                id: sqliteInt(statement, 0),
                threadID: sqliteText(statement, 1),
                ts: sqliteInt(statement, 2),
                tsNanos: sqliteInt(statement, 3),
                target: sqliteText(statement, 4) ?? "",
                feedbackLogBody: sqliteText(statement, 5) ?? ""
            )
        }
    }

    nonisolated static func rolloutReads(options: [LiveThreadOption], offsets: [String: UInt64]) throws -> [RolloutRead] {
        try options.map { option in
            let offset = offsets[option.rolloutPath] ?? fileSize(path: option.rolloutPath)
            let result = try rolloutEvents(path: option.rolloutPath, afterOffset: offset)
            return RolloutRead(threadID: option.id, path: option.rolloutPath, newOffset: result.offset, events: result.events)
        }
    }

    nonisolated static func rolloutEvents(path: String, afterOffset: UInt64) throws -> (offset: UInt64, events: [RolloutMetricEvent]) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (afterOffset, [])
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: afterOffset)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else {
            return (afterOffset, [])
        }

        var consumedText = text
        if !text.hasSuffix("\n") {
            guard let lastNewline = text.lastIndex(of: "\n") else {
                return (afterOffset, [])
            }
            consumedText = String(text[...lastNewline])
            text = String(text[..<lastNewline])
        }

        let consumedBytes = UInt64(consumedText.data(using: .utf8)?.count ?? 0)
        let newOffset = afterOffset + consumedBytes
        let events = rolloutEvents(fromLines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        return (newOffset, events)
    }

    nonisolated static func rolloutEvents(fromLines lines: [String]) -> [RolloutMetricEvent] {
        var callStarts: [String: TimeInterval] = [:]
        return lines.flatMap { rolloutEvents(fromLine: $0, callStarts: &callStarts) }
    }

    nonisolated static func rolloutEvents(fromLine line: String) -> [RolloutMetricEvent] {
        var callStarts: [String: TimeInterval] = [:]
        return rolloutEvents(fromLine: line, callStarts: &callStarts)
    }

    nonisolated static func rolloutEvents(fromLine line: String, callStarts: inout [String: TimeInterval]) -> [RolloutMetricEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return []
        }

        let timestamp = parseTimestamp(object["timestamp"] as? String)
        let recordType = object["type"] as? String
        let payloadType = payload["type"] as? String
        let keyPrefix = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString

        if recordType == "response_item", payloadType == "function_call" {
            callStarts[keyPrefix] = timestamp
            return []
        }

        if recordType == "response_item", payloadType == "custom_tool_call" {
            callStarts[keyPrefix] = timestamp
            let name = payload["name"] as? String ?? "custom_tool"
            let input = payload["input"] as? String ?? ""
            guard !input.isEmpty else { return [] }
            let category: LiveTokenCategory = name == "apply_patch" ? .patchInput : .toolArguments
            return [RolloutMetricEvent(timestamp: timestamp, key: "\(keyPrefix):\(category.rawValue)", category: category, text: input)]
        }

        if recordType == "event_msg", payloadType == "agent_message" {
            let text = payload["message"] as? String ?? ""
            guard !text.isEmpty else { return [] }
            return [
                RolloutMetricEvent(
                    timestamp: timestamp,
                    key: keyPrefix,
                    category: .visibleText,
                    text: text,
                    rollingOnly: true
                )
            ]
        }

        if recordType == "response_item", payloadType == "message",
           payload["role"] as? String == "assistant" {
            let text = messageText(from: payload)
            guard !text.isEmpty else { return [] }
            return [
                RolloutMetricEvent(
                    timestamp: timestamp,
                    key: keyPrefix,
                    category: .visibleText,
                    text: text
                )
            ]
        }

        if recordType == "response_item", payloadType == "function_call_output" {
            let output = payload["output"] as? String ?? ""
            guard !output.isEmpty else { return [] }
            return [RolloutMetricEvent(timestamp: timestamp, startTimestamp: callStarts[keyPrefix], key: "\(keyPrefix):toolOutput", category: .toolOutput, text: output)]
        }

        if recordType == "response_item", payloadType == "custom_tool_call_output" {
            let output = payload["output"] as? String ?? ""
            guard !output.isEmpty else { return [] }
            return [RolloutMetricEvent(timestamp: timestamp, startTimestamp: callStarts[keyPrefix], key: "\(keyPrefix):customToolOutput", category: .toolOutput, text: output)]
        }

        if recordType == "event_msg", payloadType == "patch_apply_end" {
            guard let changes = payload["changes"] as? [String: Any] else { return [] }
            let text = changes.values.compactMap { value -> String? in
                guard let change = value as? [String: Any] else { return nil }
                return (change["content"] as? String) ?? (change["unified_diff"] as? String)
            }.joined(separator: "\n")
            guard !text.isEmpty else { return [] }
            return [RolloutMetricEvent(timestamp: timestamp, startTimestamp: callStarts[keyPrefix], key: "\(keyPrefix):patchApplied", category: .patchApplied, text: text)]
        }

        if recordType == "event_msg", payloadType == "token_count",
           let info = payload["info"] as? [String: Any],
           let usage = info["last_token_usage"] as? [String: Any] {
            let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            return [
                RolloutMetricEvent(
                    timestamp: timestamp,
                    key: "\(keyPrefix):reasoning",
                    category: reasoning > 0 ? .reasoning : nil,
                    text: "",
                    exactTokens: reasoning > 0 ? reasoning : nil,
                    exactOutputTokens: output > 0 ? output : nil
                )
            ]
        }

        return []
    }

    nonisolated static func parseTimestamp(_ text: String?) -> TimeInterval {
        guard let text, let date = ISO8601DateFormatter().date(from: text) else {
            return Date().timeIntervalSince1970
        }
        return date.timeIntervalSince1970
    }

    nonisolated static func sqliteScalarInt(db: String, sql: String) throws -> Int {
        try sqliteRows(db: db, sql: sql) { statement in
            sqliteInt(statement, 0)
        }.first ?? 0
    }

    nonisolated static func sqliteRows<T>(db path: String, sql: String, map: (SQLiteStatement) throws -> T) throws -> [T] {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: path),
            readOnly: true,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.readRows(sql, map: map)
    }

    nonisolated static func sqliteText(_ statement: SQLiteStatement, _ column: Int32) -> String? {
        statement.text(column)
    }

    nonisolated static func sqliteInt(_ statement: SQLiteStatement, _ column: Int32) -> Int {
        statement.int(column) ?? 0
    }

    nonisolated static func streamEvent(from row: LogRow) -> ResponseStreamEvent? {
        let marker: String
        switch row.target {
        case "codex_api::sse::responses":
            marker = "SSE event: "
        case "codex_api::endpoint::responses_websocket":
            marker = "websocket event: "
        default:
            return nil
        }
        guard let range = row.feedbackLogBody.range(of: marker) else { return nil }
        let jsonText = String(row.feedbackLogBody[range.upperBound...])
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResponseStreamEvent.self, from: data)
    }

    nonisolated static func metricEvents(from streamEvent: ResponseStreamEvent, row: LogRow, toolNames: [String: String]) -> [LiveMetricEvent] {
        let timestamp = TimeInterval(row.ts) + TimeInterval(row.tsNanos) / 1_000_000_000
        let source: LiveMetricSource = row.target == "codex_api::sse::responses" ? .sse : .websocket
        let itemID = streamEvent.itemID ?? streamEvent.item?.id ?? "unknown"
        let turnID = streamEvent.item?.metadata?.turnID
        let callID = streamEvent.item?.callID

        switch streamEvent.type {
        case "response.output_text.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: .visibleText,
                    text: delta,
                    isDelta: true
                )
            ]
        case "response.function_call_arguments.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            let category = toolNames[itemID] == "apply_patch" ? LiveTokenCategory.patchInput : .toolArguments
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: category,
                    text: delta,
                    isDelta: true
                )
            ]
        case "response.custom_tool_call_input.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            let category = toolNames[itemID] == "apply_patch" ? LiveTokenCategory.patchInput : .toolArguments
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: category,
                    text: delta,
                    isDelta: true
                )
            ]
        default:
            return []
        }
    }

    nonisolated static func streamMessageText(from item: ResponseStreamItem) -> String {
        guard let content = item.content else { return "" }
        return content.compactMap { part -> String? in
            let type = part.type
            guard type == "output_text" || type == "text" else { return nil }
            return part.text
        }.joined()
    }

    nonisolated static func traceValue(in body: String, keys: [String]) -> String? {
        for key in keys {
            guard let keyRange = body.range(of: key) else { continue }
            var value = ""
            var index = keyRange.upperBound
            var quoted = false
            if index < body.endIndex, body[index] == "\"" {
                quoted = true
                index = body.index(after: index)
            }
            while index < body.endIndex {
                let char = body[index]
                if quoted {
                    if char == "\"" { break }
                } else if char == " " || char == "}" || char == ":" || char == "," {
                    break
                }
                value.append(char)
                index = body.index(after: index)
            }
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func messageText(from payload: [String: Any]) -> String {
        guard let content = payload["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "output_text" || type == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }

    nonisolated static func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    nonisolated static func fileSize(path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? UInt64 ?? 0
    }

    nonisolated private static func logStoreSignature(logsDB: String) -> LogStoreSignature {
        let database = fileSignaturePart(path: logsDB)
        let wal = fileSignaturePart(path: logsDB + "-wal")
        return LogStoreSignature(
            databaseSize: database.size,
            databaseModifiedAt: database.modifiedAt,
            walSize: wal.size,
            walModifiedAt: wal.modifiedAt
        )
    }

    nonisolated private static func fileSignaturePart(path: String) -> (size: UInt64, modifiedAt: TimeInterval) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (0, 0)
        }
        let size = attrs[.size] as? UInt64 ?? 0
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modifiedAt)
    }
}

extension CodexDataSource {
    var logsDatabase: URL {
        codexHome.appendingPathComponent("logs_2.sqlite")
    }
}
