import Foundation
import Darwin
import SQLite3
import SwiftUI
import TiktokenSwift

struct LiveRateSnapshot: Equatable {
    var threadID: String = ""
    var threadTitle: String = "等待当前会话"
    var sourceLabel: String = "logs_2.sqlite"
    var status: String = "等待输出"
    var rollingTokensPerSecond: Double = 0
    var averageTokensPerSecond: Double = 0
    var outputTokens: Int = 0
    var outputCharacters: Int = 0
    var breakdown = LiveTokenBreakdown()
    var scopeLabel: String = "单会话"
    var interfaceLabel: String = "stream deltas + calibrated"
    var updatedAt: Date = Date()

    var shortThreadID: String {
        guard !threadID.isEmpty else { return "未定位" }
        return String(threadID.prefix(8))
    }
}

struct LiveTokenBreakdown: Equatable {
    var visibleText = 0
    var toolArguments = 0
    var patchInput = 0
    var patchApplied = 0
    var toolOutput = 0
    var reasoning = 0
    var exactModelOutput = 0

    var modelGeneratedEstimate: Int {
        visibleText + toolArguments + patchInput + reasoning
    }

    var modelGenerated: Int {
        guard exactModelOutput > 0 else { return modelGeneratedEstimate }
        return max(exactModelOutput, visibleText + toolArguments + patchInput)
    }

    var observedTotal: Int {
        modelGenerated + patchApplied + toolOutput
    }
}

struct LiveThreadOption: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAtMS: Int
    let rolloutPath: String

    var displayTitle: String {
        title.isEmpty ? "未命名会话" : title
    }

    var shortID: String {
        String(id.prefix(8))
    }
}

enum LiveTokenCategory: String {
    case visibleText
    case toolArguments
    case patchInput
    case patchApplied
    case toolOutput
    case reasoning
}

enum LiveMetricSource {
    case sse
    case websocket
    case rollout
}

struct LiveMetricEvent {
    let source: LiveMetricSource
    let timestamp: TimeInterval
    let startTimestamp: TimeInterval?
    let threadID: String?
    let turnID: String?
    let itemID: String
    let callID: String?
    let sequenceNumber: Int?
    let category: LiveTokenCategory?
    let text: String
    let exactTokens: Int?
    let exactOutputTokens: Int?
    let rollingOnly: Bool
    let isDelta: Bool

    init(
        source: LiveMetricSource,
        timestamp: TimeInterval,
        startTimestamp: TimeInterval? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String,
        callID: String? = nil,
        sequenceNumber: Int? = nil,
        category: LiveTokenCategory?,
        text: String,
        exactTokens: Int? = nil,
        exactOutputTokens: Int? = nil,
        rollingOnly: Bool = false,
        isDelta: Bool = false
    ) {
        self.source = source
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.callID = callID
        self.sequenceNumber = sequenceNumber
        self.category = category
        self.text = text
        self.exactTokens = exactTokens
        self.exactOutputTokens = exactOutputTokens
        self.rollingOnly = rollingOnly
        self.isDelta = isDelta
    }
}

struct RolloutMetricEvent {
    let timestamp: TimeInterval
    let startTimestamp: TimeInterval?
    let key: String
    let category: LiveTokenCategory?
    let text: String
    let exactTokens: Int?
    let exactOutputTokens: Int?
    let rollingOnly: Bool

    init(
        timestamp: TimeInterval,
        startTimestamp: TimeInterval? = nil,
        key: String,
        category: LiveTokenCategory?,
        text: String,
        exactTokens: Int? = nil,
        exactOutputTokens: Int? = nil,
        rollingOnly: Bool = false
    ) {
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.key = key
        self.category = category
        self.text = text
        self.exactTokens = exactTokens
        self.exactOutputTokens = exactOutputTokens
        self.rollingOnly = rollingOnly
    }
}

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
    private let idlePollInterval: TimeInterval = 0.25
    private let activeFastPollHoldSeconds: TimeInterval = 10.0
    private let snapshotPublishInterval: TimeInterval = 0.25
    private let startupBackfillSeconds: TimeInterval = 4.0
    private let minimumRateSpanSeconds: TimeInterval = 0.4
    private var timer: Timer?
    private var logsDirectorySource: DispatchSourceFileSystemObject?
    private var watchedLogsDirectory = ""
    private var logChangePending = false
    private var fastPollUntil: TimeInterval = 0
    private var threadID = ""
    private var lastLogID = 0
    private var lastGlobalLogID = 0
    private var lastLogsSignature: LogStoreSignature?
    private var lastPollProcessedRows = false
    private var lastSnapshotPublishAt: TimeInterval = 0
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
        fastPollInterval
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
        dataSource = source
        configureLogWatcher(for: source)
        lastLogsSignature = Self.logStoreSignature(logsDB: source.logsDatabase.path)

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
            let logsDB = source.logsDatabase.path
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
            let rows = try await Task.detached(priority: .utility) {
                try Self.globalLogRows(logsDB: logsDB, since: since)
            }.value
            guard !rows.isEmpty else { return }
            for row in rows {
                lastGlobalLogID = max(lastGlobalLogID, row.id)
                add(row: row)
            }
            extendFastPolling(from: Date().timeIntervalSince1970)
            updateSnapshots(now: Date().timeIntervalSince1970)
            lastLogsSignature = Self.logStoreSignature(logsDB: source.logsDatabase.path)
        } catch {
            snapshot.status = "启动回看日志失败：\(error.localizedDescription)"
        }
    }

    private func switchToThread(_ id: String) async {
        guard let source = dataSource ?? resolver.resolve() else { return }
        dataSource = source
        configureLogWatcher(for: source)
        do {
            let logsDB = source.logsDatabase.path
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
        lastPollProcessedRows = false
        guard let source = dataSource ?? resolver.resolve() else { return }
        dataSource = source
        configureLogWatcher(for: source)
        if threadID.isEmpty {
            await resetToLatestThread()
            return
        }

        do {
            let logsDB = source.logsDatabase.path
            let signature = Self.logStoreSignature(logsDB: logsDB)
            let now = Date().timeIntervalSince1970
            let signatureChanged = lastLogsSignature != signature
            logChangePending = false
            if signatureChanged {
                lastLogsSignature = signature
            }

            let currentGlobalLogID = lastGlobalLogID
            let globalRows = try await Task.detached(priority: .utility) {
                try Self.globalLogRows(logsDB: logsDB, afterID: currentGlobalLogID)
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

    private func configureLogWatcher(for source: CodexDataSource) {
        let directory = source.logsDatabase.deletingLastPathComponent().path
        guard watchedLogsDirectory != directory else { return }

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

        guard abs(snapshot.rollingTokensPerSecond - updated.rollingTokensPerSecond) > 0.01
            || abs(snapshot.averageTokensPerSecond - updated.averageTokensPerSecond) > 0.01
            || snapshot.outputTokens != updated.outputTokens
            || snapshot.outputCharacters != updated.outputCharacters
            || snapshot.breakdown != updated.breakdown
            || snapshot.status != updated.status else {
            return nil
        }

        updated.updatedAt = Date()
        return updated
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
    struct ThreadRow: Decodable {
        let id: String
        let title: String
        let updatedAtMS: Int
        let rolloutPath: String

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case updatedAtMS = "updated_at_ms"
            case rolloutPath = "rollout_path"
        }
    }

    struct LogRow: Decodable {
        let id: Int
        let threadID: String?
        let ts: Int
        let tsNanos: Int
        let target: String
        let feedbackLogBody: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
            case ts
            case tsNanos = "ts_nanos"
            case target
            case feedbackLogBody = "feedback_log_body"
        }
    }

    struct ResponseStreamEvent: Decodable {
        let type: String
        let delta: String?
        let text: String?
        let itemID: String?
        let sequenceNumber: Int?
        let arguments: String?
        let item: ResponseStreamItem?
        let response: ResponseStreamResponse?

        enum CodingKeys: String, CodingKey {
            case type
            case delta
            case text
            case itemID = "item_id"
            case sequenceNumber = "sequence_number"
            case arguments
            case item
            case response
        }
    }

    struct ResponseStreamItem: Decodable {
        let id: String
        let type: String
        let name: String?
        let callID: String?
        let arguments: String?
        let input: String?
        let content: [ResponseStreamContentPart]?
        let metadata: ResponseStreamMetadata?

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case name
            case callID = "call_id"
            case arguments
            case input
            case content
            case metadata
        }
    }

    struct ResponseStreamContentPart: Decodable {
        let type: String?
        let text: String?
    }

    struct ResponseStreamMetadata: Decodable {
        let turnID: String?

        enum CodingKeys: String, CodingKey {
            case turnID = "turn_id"
        }
    }

    struct ResponseStreamResponse: Decodable {
        let usage: ResponseStreamUsage?
    }

    struct ResponseStreamUsage: Decodable {
        let outputTokens: Int?
        let reasoningOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }
    }

    struct RolloutRead {
        let threadID: String
        let path: String
        let newOffset: UInt64
        let events: [RolloutMetricEvent]
    }

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
        return try sqliteLogRows(db: logsDB, sql: sql)
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

    nonisolated static func globalLogRows(logsDB: String, afterID: Int) throws -> [LogRow] {
        let sql = """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE id > \(afterID)
          AND (
            (
              target = 'codex_api::sse::responses'
              AND (
                feedback_log_body LIKE 'SSE event:%'
                OR feedback_log_body LIKE '%thread.id=%'
                OR feedback_log_body LIKE '%thread_id=%'
                OR feedback_log_body LIKE '%conversation.id=%'
              )
            )
            OR (
              target = 'codex_api::endpoint::responses_websocket'
              AND feedback_log_body LIKE '%websocket event:%'
            )
          )
        ORDER BY id ASC
        LIMIT 2000;
        """
        return try sqliteLogRows(db: logsDB, sql: sql)
    }

    nonisolated static func globalLogRows(logsDB: String, since timestamp: TimeInterval) throws -> [LogRow] {
        let sinceSeconds = Int(timestamp.rounded(.down))
        let sql = """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE ts >= \(sinceSeconds)
          AND (
            (
              target = 'codex_api::sse::responses'
              AND (
                feedback_log_body LIKE 'SSE event:%'
                OR feedback_log_body LIKE '%thread.id=%'
                OR feedback_log_body LIKE '%thread_id=%'
                OR feedback_log_body LIKE '%conversation.id=%'
              )
            )
            OR (
              target = 'codex_api::endpoint::responses_websocket'
              AND feedback_log_body LIKE '%websocket event:%'
            )
          )
        ORDER BY id ASC
        LIMIT 2000;
        """
        return try sqliteLogRows(db: logsDB, sql: sql)
    }

    nonisolated static func sqliteLogRows(db: String, sql: String) throws -> [LogRow] {
        try sqliteRows(db: db, sql: sql) { statement in
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

    nonisolated static func sqliteScalarInt(db: String, sql: String) throws -> Int {
        try sqliteRows(db: db, sql: sql) { statement in
            sqliteInt(statement, 0)
        }.first ?? 0
    }

    nonisolated static func sqliteRows<T>(db path: String, sql: String, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { sqliteErrorMessage($0) } ?? "Unable to open SQLite database"
            if let database {
                sqlite3_close(database)
            }
            throw NSError(domain: "CodexTokenDashboard", code: Int(openStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw NSError(domain: "CodexTokenDashboard", code: Int(prepareStatus), userInfo: [NSLocalizedDescriptionKey: sqliteErrorMessage(database)])
        }
        defer { sqlite3_finalize(statement) }

        var rows: [T] = []
        while true {
            let stepStatus = sqlite3_step(statement)
            if stepStatus == SQLITE_ROW {
                rows.append(try map(statement))
            } else if stepStatus == SQLITE_DONE {
                return rows
            } else {
                throw NSError(domain: "CodexTokenDashboard", code: Int(stepStatus), userInfo: [NSLocalizedDescriptionKey: sqliteErrorMessage(database)])
            }
        }
    }

    nonisolated static func sqliteText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    nonisolated static func sqliteInt(_ statement: OpaquePointer?, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    nonisolated static func sqliteErrorMessage(_ database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else { return "SQLite error" }
        return String(cString: message)
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

    nonisolated static func sqliteJSON<T: Decodable>(db: String, sql: String) throws -> [T] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", db, sql]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw NSError(domain: "CodexTokenDashboard", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }

        if data.isEmpty {
            return []
        }
        return try JSONDecoder().decode([T].self, from: data)
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

private struct RateAccumulator {
    // Completion-only payloads arrive after a tool/edit finishes. Spread them with
    // a conservative virtual rate so the live gauge does not show a completion spike.
    private static let completionPayloadTokensPerSecond: Double = 55
    private static let minimumCompletionPayloadSeconds: TimeInterval = 1
    private static let maximumCompletionPayloadSeconds: TimeInterval = 30
    private static let distributionStepSeconds: TimeInterval = 0.5

    let resetsOnNewItem: Bool
    private(set) var breakdown = LiveTokenBreakdown()
    var outputTokens: Int { breakdown.observedTotal }
    private(set) var outputCharacters = 0
    private var currentKey = ""
    private var itemText: [String: String] = [:]
    private var itemTokens: [String: Int] = [:]
    private var firstDeltaAt: TimeInterval?
    private var lastDeltaAt: TimeInterval?
    private var rollingDeltas: [(time: TimeInterval, tokens: Int)] = []

    init(resetsOnNewItem: Bool) {
        self.resetsOnNewItem = resetsOnNewItem
    }

    var averageRate: Double {
        guard let firstDeltaAt, let lastDeltaAt else { return 0 }
        return Double(outputTokens) / max(0.25, lastDeltaAt - firstDeltaAt)
    }

    mutating func clear() {
        breakdown = LiveTokenBreakdown()
        outputCharacters = 0
        currentKey = ""
        itemText.removeAll()
        itemTokens.removeAll()
        firstDeltaAt = nil
        lastDeltaAt = nil
        rollingDeltas.removeAll()
    }

    mutating func add(
        delta: String,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        if resetsOnNewItem, !currentKey.isEmpty, key != currentKey {
            clear()
        }
        currentKey = key

        let previousText = itemText[key] ?? ""
        let nextText = previousText + delta
        let previousTokens = itemTokens[key] ?? 0
        let nextTokens = estimator(nextText)
        let deltaTokens = max(0, nextTokens - previousTokens)

        itemText[key] = nextText
        itemTokens[key] = nextTokens
        outputCharacters += delta.count

        guard deltaTokens > 0 else { return }
        add(tokens: deltaTokens, category: category, key: key, at: timestamp, windowSeconds: windowSeconds)
    }

    mutating func add(
        text: String,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        let tokens = estimator(text)
        outputCharacters += text.count
        add(tokens: tokens, category: category, key: key, at: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addRollingOnly(
        text: String,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        let tokens = estimator(text)
        guard tokens > 0 else { return }
        currentKey = key
        outputCharacters += text.count
        if firstDeltaAt == nil {
            firstDeltaAt = timestamp
        }
        lastDeltaAt = timestamp
        rollingDeltas.append((timestamp, tokens))
        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addDistributed(
        text: String,
        category: LiveTokenCategory,
        key: String,
        startTimestamp: TimeInterval?,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        let tokens = estimator(text)
        outputCharacters += text.count
        addDistributed(tokens: tokens, category: category, key: key, startTimestamp: startTimestamp, endingAt: timestamp, windowSeconds: windowSeconds)
    }

    mutating func add(
        tokens: Int,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        guard tokens > 0 else { return }
        currentKey = key
        addToBreakdown(tokens: tokens, category: category)
        if firstDeltaAt == nil {
            firstDeltaAt = timestamp
        }
        lastDeltaAt = timestamp
        rollingDeltas.append((timestamp, tokens))
        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addDistributed(
        tokens: Int,
        category: LiveTokenCategory,
        key: String,
        startTimestamp: TimeInterval?,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        guard tokens > 0 else { return }
        currentKey = key
        let previousTokens = itemTokens[key] ?? 0
        let deltaTokens = max(0, tokens - previousTokens)
        itemTokens[key] = max(previousTokens, tokens)
        guard deltaTokens > 0 else { return }

        addToBreakdown(tokens: deltaTokens, category: category)

        let estimatedDuration = estimatedDistributionDuration(tokens: deltaTokens)
        let start: TimeInterval
        let duration: TimeInterval
        let spreadsForward = startTimestamp == nil
        if let startTimestamp {
            start = min(startTimestamp, timestamp)
            duration = max(0.25, max(timestamp - start, estimatedDuration))
        } else {
            start = timestamp
            duration = estimatedDuration
        }

        if firstDeltaAt == nil {
            firstDeltaAt = start
        } else if let existing = firstDeltaAt {
            firstDeltaAt = min(existing, start)
        }
        lastDeltaAt = spreadsForward ? timestamp + duration : timestamp

        let chunkCount = max(1, min(deltaTokens, Int(ceil(duration / Self.distributionStepSeconds))))
        var emitted = 0
        for index in 1...chunkCount {
            let cumulative = Int((Double(deltaTokens) * Double(index) / Double(chunkCount)).rounded())
            let chunkTokens = cumulative - emitted
            emitted = cumulative
            guard chunkTokens > 0 else { continue }
            let ratio = Double(index) / Double(chunkCount)
            let chunkTime = spreadsForward ? start + duration * ratio : start + duration * ratio
            rollingDeltas.append((chunkTime, chunkTokens))
        }

        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addExactModelOutput(_ tokens: Int) {
        guard tokens > 0 else { return }
        breakdown.exactModelOutput += tokens
    }

    mutating func prune(now: TimeInterval, windowSeconds: TimeInterval) {
        rollingDeltas.removeAll { now - $0.time > windowSeconds }
    }

    func rollingRate(now: TimeInterval, windowSeconds: TimeInterval, minimumSpan: TimeInterval) -> Double {
        let visibleDeltas = rollingDeltas.filter { $0.time <= now }
        guard let first = visibleDeltas.first else { return 0 }
        let span = max(minimumSpan, min(windowSeconds, now - first.time))
        return Double(visibleDeltas.reduce(0) { $0 + $1.tokens }) / span
    }

    func hasRecentActivity(now: TimeInterval, windowSeconds: TimeInterval) -> Bool {
        rollingDeltas.contains { $0.time <= now && now - $0.time <= windowSeconds }
    }

    private mutating func addToBreakdown(tokens: Int, category: LiveTokenCategory) {
        switch category {
        case .visibleText:
            breakdown.visibleText += tokens
        case .toolArguments:
            breakdown.toolArguments += tokens
        case .patchInput:
            breakdown.patchInput += tokens
        case .patchApplied:
            breakdown.patchApplied += tokens
        case .toolOutput:
            breakdown.toolOutput += tokens
        case .reasoning:
            breakdown.reasoning += tokens
        }
    }

    private func estimatedDistributionDuration(tokens: Int) -> TimeInterval {
        min(
            Self.maximumCompletionPayloadSeconds,
            max(Self.minimumCompletionPayloadSeconds, Double(tokens) / Self.completionPayloadTokensPerSecond)
        )
    }
}
