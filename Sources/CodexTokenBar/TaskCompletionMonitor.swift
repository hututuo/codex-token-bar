import Foundation
import SQLite3

@MainActor
final class TaskCompletionMonitor: ObservableObject {
    @Published private(set) var statusText = "未读监听准备中"
    @Published private(set) var detailText = "Codex 有未读会话时在悬浮窗显示小红点"
    @Published private(set) var lastCompletedTitle = ""
    @Published private(set) var unreadThreadCount = 0

    private let pollInterval: TimeInterval = 2.0
    private let liveSeedWindow: TimeInterval = 30.0
    private var dataSource: CodexDataSource?
    private var fileStates: [String: TaskCompletionFileState] = [:]
    private var completedEventIDs: Set<String> = []
    private var completedTaskThreadIDs: [String: String] = [:]
    private var unreadThreadState = CodexUnreadThreadState()
    private var hasCodexUnreadState = false
    private var timer: Timer?
    private var isPolling = false
    private var seeded = false
    private var monitorStartedAt = Date()

    init() {
        updateStatusText()
    }

    func start(dataSource: CodexDataSource?) {
        let oldPath = self.dataSource?.codexHome.path
        let newPath = dataSource?.codexHome.path
        self.dataSource = dataSource

        if oldPath != newPath {
            fileStates.removeAll()
            seeded = false
            monitorStartedAt = Date()
            completedEventIDs.removeAll()
            completedTaskThreadIDs.removeAll()
            unreadThreadState = CodexUnreadThreadState()
            hasCodexUnreadState = false
            unreadThreadCount = 0
        }

        updateStatusText()
        configureTimer()
    }

    func refreshUnreadThreadStatus() {
        guard dataSource != nil else { return }
        if let codexHome = dataSource?.codexHome {
            applyCodexUnreadRead(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome))
        }

        if hasCodexUnreadState {
            completedTaskThreadIDs = completedTaskThreadIDs.filter { _, threadID in
                unreadThreadState.threadIDs.contains(threadID)
            }
        } else {
            completedTaskThreadIDs.removeAll()
        }
        recomputeUnreadThreadCount()
        updateStatusText(fileCount: fileStates.count)
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil

        guard dataSource != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    private func poll() {
        guard !isPolling, let dataSource else {
            return
        }

        isPolling = true
        let root = dataSource.sessionsRoot
        let previousStates = fileStates
        let seedMode = !seeded
        let seedCutoff = monitorStartedAt.addingTimeInterval(-liveSeedWindow)
        let codexHome = dataSource.codexHome

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                TaskCompletionScanner.scan(
                    sessionsRoot: root,
                    previousStates: previousStates,
                    seedMode: seedMode,
                    seedCutoff: seedCutoff
                )
            }.value
            let unreadThreadRead = await Task.detached(priority: .utility) {
                CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)
            }.value

            await MainActor.run {
                self?.apply(result, unreadThreadRead: unreadThreadRead)
            }
        }
    }

    private func apply(_ result: TaskCompletionScanResult, unreadThreadRead: CodexUnreadThreadReadResult) {
        fileStates = result.states
        seeded = true
        isPolling = false
        applyCodexUnreadRead(unreadThreadRead)

        if result.fileCount == 0 {
            statusText = "未发现会话日志"
            detailText = "等待 Codex 写入 sessions"
        } else if result.events.isEmpty {
            updateStatusText(fileCount: result.fileCount)
        }

        var didAddUnread = false
        for event in result.events {
            guard completedEventIDs.insert(event.id).inserted else { continue }
            lastCompletedTitle = event.title
            completedTaskThreadIDs[event.id] = event.threadID
            didAddUnread = true
        }

        recomputeUnreadThreadCount()
        if didAddUnread, !hasCodexUnreadState, unreadThreadCount > 0 {
            statusText = "有任务完成"
            detailText = lastCompletedTitle
        } else {
            updateStatusText(fileCount: result.fileCount)
        }
    }

    private func recomputeUnreadThreadCount() {
        if hasCodexUnreadState {
            unreadThreadCount = unreadThreadState.threadIDs.count
        } else {
            unreadThreadCount = Set(completedTaskThreadIDs.values).count
        }
    }

    private func applyCodexUnreadRead(_ result: CodexUnreadThreadReadResult) {
        guard case let .available(threadIDs) = result else { return }
        unreadThreadState = CodexUnreadThreadState(threadIDs: threadIDs)
        hasCodexUnreadState = true
    }

    private func updateStatusText(fileCount: Int? = nil) {
        if unreadThreadCount > 0 {
            if hasCodexUnreadState {
                statusText = "有未读会话"
                detailText = "Codex 有 \(unreadThreadCount) 个未读会话"
            } else {
                statusText = "有任务完成"
                detailText = lastCompletedTitle.isEmpty ? "等待 Codex 未读状态同步" : lastCompletedTitle
            }
            return
        }

        if dataSource == nil {
            statusText = "未找到 Codex 目录"
            detailText = "选择目录后开始监听"
            return
        }

        statusText = "未读监听中"
        if let fileCount {
            detailText = "已跟踪 \(fileCount) 个会话文件"
        } else {
            detailText = "Codex 有未读会话时会亮点"
        }
    }
}

private struct TaskCompletionFileState: Sendable {
    var offset: UInt64
    var sessionID: String
    var cwd: String
    var isSubagent: Bool
    var lastUserText: String
    var activeTurns: [String: TaskCompletionTurnState]
}

private struct TaskCompletionTurnState: Sendable {
    var startedAt: TimeInterval
    var lastUserText: String
}

private struct TaskCompletionEvent: Sendable {
    let id: String
    let threadID: String
    let title: String
    let body: String
}

private struct TaskCompletionScanResult: Sendable {
    let states: [String: TaskCompletionFileState]
    let events: [TaskCompletionEvent]
    let fileCount: Int
}

private struct CodexUnreadThreadState: Sendable {
    var threadIDs: Set<String> = []
}

private enum CodexUnreadThreadReadResult: Sendable {
    case available(Set<String>)
    case unavailable
}

private enum CodexUnreadThreadReader {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func readUnreadThreadIDs(codexHome: URL) -> CodexUnreadThreadReadResult {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable
        }
        guard let unreadState = unreadStateValue(in: object) else {
            return .available([])
        }
        let threadIDs = collectThreadIDs(from: unreadState)
        return .available(visibleUserThreadIDs(from: threadIDs, codexHome: codexHome))
    }

    private static func unreadStateValue(in object: [String: Any]) -> Any? {
        if let persistedState = object["electron-persisted-atom-state"] as? [String: Any],
           let value = persistedState["unread-thread-ids-by-host-v1"] {
            return value
        }
        return object["unread-thread-ids-by-host-v1"]
    }

    private static func collectThreadIDs(from value: Any) -> Set<String> {
        var threadIDs = Set<String>()
        if let string = value as? String {
            if looksLikeThreadID(string) {
                threadIDs.insert(string)
            }
            return threadIDs
        }
        if let strings = value as? [String] {
            threadIDs.formUnion(strings.filter(looksLikeThreadID))
            return threadIDs
        }
        if let array = value as? [Any] {
            for item in array {
                threadIDs.formUnion(collectThreadIDs(from: item))
            }
            return threadIDs
        }
        if let dictionary = value as? [String: Any] {
            for item in dictionary.values {
                threadIDs.formUnion(collectThreadIDs(from: item))
            }
        }
        return threadIDs
    }

    private static func looksLikeThreadID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 24 && trimmed.contains("-")
    }

    private static func visibleUserThreadIDs(from threadIDs: Set<String>, codexHome: URL) -> Set<String> {
        guard !threadIDs.isEmpty else { return [] }
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return sessionVisibleThreadIDs(from: threadIDs, codexHome: codexHome).visibleIDs
        }

        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return sessionVisibleThreadIDs(from: threadIDs, codexHome: codexHome).visibleIDs
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        let columns = threadTableColumns(database)
        let archivedExpression = columns.contains("archived") ? "COALESCE(archived, 0)" : "0"
        let hasUserEventExpression = columns.contains("has_user_event") ? "COALESCE(has_user_event, 0)" : "1"
        let threadSourceExpression = columns.contains("thread_source") ? "COALESCE(thread_source, 'user')" : "'user'"
        let sourceExpression = columns.contains("source") ? "COALESCE(source, '')" : "''"
        let previewExpression = columns.contains("preview") ? "COALESCE(preview, '')" : "'legacy'"
        let placeholders = Array(repeating: "?", count: threadIDs.count).joined(separator: ",")
        let sql = """
        SELECT id, \(archivedExpression), \(hasUserEventExpression), \(threadSourceExpression), \(sourceExpression), \(previewExpression)
        FROM threads
        WHERE id IN (\(placeholders))
        """

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            return sessionVisibleThreadIDs(from: threadIDs, codexHome: codexHome).visibleIDs
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in threadIDs.sorted().enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, sqliteTransient)
        }

        var visibleIDs = Set<String>()
        var matchedIDs = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let id = String(cString: text)
                matchedIDs.insert(id)
                let archived = sqlite3_column_int(statement, 1) != 0
                let hasUserEvent = sqlite3_column_int(statement, 2) != 0
                let threadSource = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "user"
                let source = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                let preview = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
                if !archived,
                   hasUserEvent,
                   !preview.isEmpty,
                   !threadSource.localizedCaseInsensitiveContains("subagent"),
                   !source.localizedCaseInsensitiveContains("subagent") {
                    visibleIDs.insert(id)
                }
            }
        }

        let unresolvedIDs = threadIDs.subtracting(matchedIDs)
        if !unresolvedIDs.isEmpty {
            let sessionVisibility = sessionVisibleThreadIDs(from: unresolvedIDs, codexHome: codexHome)
            visibleIDs.formUnion(sessionVisibility.visibleIDs)
        }
        return visibleIDs
    }

    private static func threadTableColumns(_ database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: text))
            }
        }
        return columns
    }

    private struct SessionVisibility {
        var visibleIDs = Set<String>()
        var foundIDs = Set<String>()
    }

    private static func sessionVisibleThreadIDs(from threadIDs: Set<String>, codexHome: URL) -> SessionVisibility {
        var visibility = SessionVisibility()
        guard !threadIDs.isEmpty else { return visibility }

        let liveSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        scanSessionMetas(under: liveSessions, archived: false, threadIDs: threadIDs, visibility: &visibility)

        let archivedSessions = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        scanSessionMetas(under: archivedSessions, archived: true, threadIDs: threadIDs, visibility: &visibility)
        return visibility
    }

    private static func scanSessionMetas(
        under root: URL,
        archived: Bool,
        threadIDs: Set<String>,
        visibility: inout SessionVisibility
    ) {
        guard visibility.foundIDs.count < threadIDs.count,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for item in enumerator {
            guard visibility.foundIDs.count < threadIDs.count,
                  let file = item as? URL,
                  file.pathExtension == "jsonl",
                  let payload = sessionMetaPayload(in: file),
                  let id = payload["id"] as? String,
                  threadIDs.contains(id) else {
                continue
            }

            visibility.foundIDs.insert(id)
            let threadSource = payload["thread_source"] as? String ?? ""
            let isSubagent = threadSource.localizedCaseInsensitiveContains("subagent")
                || valueContainsSubagent(payload["source"])
            if !archived && !isSubagent {
                visibility.visibleIDs.insert(id)
            }
        }
    }

    private static func sessionMetaPayload(in file: URL) -> [String: Any]? {
        guard let firstLine = firstLine(in: file),
              let data = firstLine.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "session_meta" else {
            return nil
        }
        return object["payload"] as? [String: Any]
    }

    private static func firstLine(in file: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(16_384, maxBytes - data.count))
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: newline) {
                data.append(chunk[..<newlineIndex])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func valueContainsSubagent(_ value: Any?) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains("subagent")
        }
        if let array = value as? [Any] {
            return array.contains(where: valueContainsSubagent)
        }
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: { $0.localizedCaseInsensitiveContains("subagent") }) {
                return true
            }
            return dictionary.values.contains(where: valueContainsSubagent)
        }
        return false
    }
}

private final class TaskCompletionDateParsers {
    private let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let plainISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func date(from raw: String) -> Date? {
        if let date = fractionalISO8601Formatter.date(from: raw) {
            return date
        }
        return plainISO8601Formatter.date(from: raw)
    }
}

private enum TaskCompletionScanner {
    static func scan(
        sessionsRoot: URL,
        previousStates: [String: TaskCompletionFileState],
        seedMode: Bool,
        seedCutoff: Date
    ) -> TaskCompletionScanResult {
        let files = sessionFiles(under: sessionsRoot)
        var states = previousStates
        var events: [TaskCompletionEvent] = []
        let dateParsers = TaskCompletionDateParsers()

        for file in files {
            let path = file.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let fileSize = attributes[.size] as? NSNumber else {
                continue
            }

            let size = fileSize.uint64Value
            var state = states[path] ?? initialState(for: file, offset: 0)
            if state.offset > size {
                state.offset = 0
            }

            if states[path] == nil, seedMode {
                let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
                if modifiedAt < seedCutoff {
                    state.offset = size
                    states[path] = state
                    continue
                }
            }

            guard size > state.offset else {
                states[path] = state
                continue
            }

            let parsed = parseNewLines(
                in: file,
                from: state.offset,
                size: size,
                state: state,
                dateParsers: dateParsers
            )
            states[path] = parsed.state
            events.append(contentsOf: parsed.events)
        }

        let livePaths = Set(files.map(\.path))
        states = states.filter { livePaths.contains($0.key) }
        return TaskCompletionScanResult(states: states, events: events, fileCount: files.count)
    }

    private static func sessionFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private static func initialState(for file: URL, offset: UInt64) -> TaskCompletionFileState {
        var state = TaskCompletionFileState(
            offset: offset,
            sessionID: "",
            cwd: file.deletingLastPathComponent().path,
            isSubagent: false,
            lastUserText: "",
            activeTurns: [:]
        )

        if let firstLine = firstLine(in: file),
           let object = jsonObject(firstLine),
           object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            state.sessionID = payload["id"] as? String ?? ""
            state.cwd = payload["cwd"] as? String ?? state.cwd
            let threadSource = payload["thread_source"] as? String ?? ""
            state.isSubagent = threadSource.localizedCaseInsensitiveContains("subagent")
                || valueContainsSubagent(payload["source"])
        }
        return state
    }

    private static func parseNewLines(
        in file: URL,
        from offset: UInt64,
        size: UInt64,
        state: TaskCompletionFileState,
        dateParsers: TaskCompletionDateParsers
    ) -> (state: TaskCompletionFileState, events: [TaskCompletionEvent]) {
        var state = state
        var events: [TaskCompletionEvent] = []

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (state, events)
        }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return (state, events)
        }

        let data = handle.readDataToEndOfFile()
        guard let chunk = String(data: data, encoding: .utf8) else {
            state.offset = size
            return (state, events)
        }

        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = jsonObject(String(line)),
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }

            switch payloadType {
            case "task_started":
                guard let turnID = payload["turn_id"] as? String else { break }
                let startedAt = number(payload["started_at"]) ?? timestamp(object["timestamp"] as? String, dateParsers: dateParsers)
                state.activeTurns[turnID] = TaskCompletionTurnState(startedAt: startedAt, lastUserText: state.lastUserText)
            case "user_message":
                state.lastUserText = (payload["message"] as? String ?? "").trimmedForNotification
                for turnID in state.activeTurns.keys {
                    state.activeTurns[turnID]?.lastUserText = state.lastUserText
                }
            case "request_user_input":
                break
            case "task_complete":
                guard let turnID = payload["turn_id"] as? String else { break }
                let completedAt = number(payload["completed_at"]) ?? timestamp(object["timestamp"] as? String, dateParsers: dateParsers)
                let duration = (number(payload["duration_ms"]).map { $0 / 1000 })
                    ?? state.activeTurns[turnID].map { max(0, completedAt - $0.startedAt) }
                    ?? 0
                let turnState = state.activeTurns.removeValue(forKey: turnID)

                guard !state.isSubagent else {
                    break
                }

                events.append(
                    TaskCompletionEvent(
                        id: "\(state.sessionID)-\(turnID)-\(Int(completedAt))",
                        threadID: state.sessionID,
                        title: notificationTitle(state: state, turn: turnState),
                        body: notificationBody(duration: duration, payload: payload)
                    )
                )
            default:
                break
            }
        }

        state.offset = size
        return (state, events)
    }

    private static func firstLine(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer {
            try? handle.close()
        }

        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty || byte.first == 10 {
                break
            }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func valueContainsSubagent(_ value: Any?) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains("subagent")
        }
        if let array = value as? [Any] {
            return array.contains(where: valueContainsSubagent)
        }
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: { $0.localizedCaseInsensitiveContains("subagent") }) {
                return true
            }
            return dictionary.values.contains(where: valueContainsSubagent)
        }
        return false
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        return nil
    }

    private static func timestamp(_ raw: String?, dateParsers: TaskCompletionDateParsers) -> TimeInterval {
        guard let raw,
              let date = dateParsers.date(from: raw) else {
            return Date().timeIntervalSince1970
        }
        return date.timeIntervalSince1970
    }

    private static func notificationTitle(state: TaskCompletionFileState, turn: TaskCompletionTurnState?) -> String {
        if let userText = turn?.lastUserText, !userText.isEmpty {
            return userText
        }
        let name = URL(fileURLWithPath: state.cwd).lastPathComponent
        return name.isEmpty ? "Codex 会话" : name
    }

    private static func notificationBody(duration: TimeInterval, payload: [String: Any]) -> String {
        let answer = (payload["last_agent_message"] as? String ?? "").trimmedForNotification
        let time = durationText(duration)
        if answer.isEmpty {
            return "耗时 \(time) · 已完成回复"
        }
        return "耗时 \(time) · \(answer)"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)秒"
        }
        let minutes = total / 60
        let rest = total % 60
        if minutes < 60 {
            return rest == 0 ? "\(minutes)分钟" : "\(minutes)分\(rest)秒"
        }
        let hours = minutes / 60
        return "\(hours)小时\(minutes % 60)分"
    }
}

private extension String {
    var trimmedForNotification: String {
        let collapsed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= 84 {
            return collapsed
        }
        return String(collapsed.prefix(82)) + "..."
    }
}
