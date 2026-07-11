import Foundation

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

enum TaskCompletionScanner {
    private static let seedTailByteLimit: UInt64 = 4 * 1024 * 1024

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
            let hadState = states[path] != nil
            var state = states[path] ?? baseState(for: file, offset: 0)
            if state.offset > size {
                state = initialState(for: file, offset: 0)
            }

            if !hadState, seedMode {
                let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
                if modifiedAt < seedCutoff {
                    state.offset = size
                    states[path] = state
                    continue
                }
                let startOffset = seedStartOffset(forSize: size)
                state = initialState(for: file, offset: startOffset)
            }

            guard size > state.offset else {
                states[path] = state
                continue
            }

            if state.sessionID.isEmpty {
                state = initialState(for: file, offset: state.offset)
            }

            let parsed = parseNewLines(
                in: file,
                from: state.offset,
                state: state,
                dateParsers: dateParsers,
                eventCutoff: seedMode ? seedCutoff.timeIntervalSince1970 : nil
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

    private static func baseState(for file: URL, offset: UInt64) -> TaskCompletionFileState {
        TaskCompletionFileState(
            offset: offset,
            sessionID: "",
            cwd: file.deletingLastPathComponent().path,
            isSubagent: false,
            lastUserText: "",
            activeTurns: [:]
        )
    }

    private static func seedStartOffset(forSize size: UInt64) -> UInt64 {
        guard size > seedTailByteLimit else { return 0 }
        return size - seedTailByteLimit
    }

    private static func initialState(for file: URL, offset: UInt64) -> TaskCompletionFileState {
        var state = baseState(for: file, offset: offset)

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
        state: TaskCompletionFileState,
        dateParsers: TaskCompletionDateParsers,
        eventCutoff: TimeInterval?
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
        guard let lastNewline = data.lastIndex(of: 10) else {
            return (state, events)
        }
        let completeByteCount = data.distance(from: data.startIndex, to: data.index(after: lastNewline))
        let chunk = String(decoding: data.prefix(completeByteCount), as: UTF8.self)

        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineString = String(line)
            guard lineString.contains("event_msg"),
                  lineString.contains("task_started") || lineString.contains("user_message") || lineString.contains("task_complete") else {
                continue
            }

            guard let object = jsonObject(lineString),
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }

            switch payloadType {
            case "task_started":
                guard let turnID = payload["turn_id"] as? String else { break }
                guard let startedAt = number(payload["started_at"])
                    ?? timestamp(object["timestamp"] as? String, dateParsers: dateParsers)
                else {
                    break
                }
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
                guard let completedAt = number(payload["completed_at"])
                    ?? timestamp(object["timestamp"] as? String, dateParsers: dateParsers)
                else {
                    break
                }
                let duration = (number(payload["duration_ms"]).map { $0 / 1000 })
                    ?? state.activeTurns[turnID].map { max(0, completedAt - $0.startedAt) }
                    ?? 0
                let turnState = state.activeTurns.removeValue(forKey: turnID)

                guard !state.isSubagent else {
                    break
                }
                if let eventCutoff, completedAt < eventCutoff {
                    break
                }

                events.append(
                    TaskCompletionEvent(
                        id: "\(state.sessionID):\(turnID)",
                        threadID: state.sessionID,
                        title: notificationTitle(state: state, turn: turnState),
                        body: notificationBody(duration: duration, payload: payload),
                        legacyIDs: ["\(state.sessionID)-\(turnID)-\(Int(completedAt))"]
                    )
                )
            default:
                break
            }
        }

        state.offset = offset + UInt64(completeByteCount)
        return (state, events)
    }

    private static func firstLine(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer {
            try? handle.close()
        }

        var data = Data()
        let maxBytes = 262_144
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(16_384, maxBytes - data.count))
            if chunk.isEmpty {
                break
            }
            if let newlineIndex = chunk.firstIndex(of: 10) {
                data.append(chunk[..<newlineIndex])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
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

    private static func timestamp(_ raw: String?, dateParsers: TaskCompletionDateParsers) -> TimeInterval? {
        guard let raw,
              let date = dateParsers.date(from: raw) else {
            return nil
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
