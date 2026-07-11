import Foundation

extension LiveRateMonitor {
    nonisolated static func rolloutReads(options: [LiveThreadOption], offsets: [String: UInt64]) throws -> [RolloutRead] {
        try options.compactMap { option in
            guard let path = option.normalizedRolloutPath else { return nil }
            let offset = offsets[path] ?? fileSize(path: path)
            let result = try rolloutEvents(path: path, afterOffset: offset)
            return RolloutRead(threadID: option.id, path: path, newOffset: result.offset, events: result.events)
        }
    }

    nonisolated static func rolloutEvents(path: String, afterOffset: UInt64) throws -> (offset: UInt64, events: [RolloutMetricEvent]) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (afterOffset, [])
        }
        let currentSize = fileSize(path: path)
        if currentSize == afterOffset {
            return (currentSize, [])
        }
        let readOffset: UInt64 = currentSize < afterOffset ? 0 : afterOffset

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: readOffset)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else {
            return (readOffset, [])
        }

        var consumedText = text
        if !text.hasSuffix("\n") {
            guard let lastNewline = text.lastIndex(of: "\n") else {
                return (readOffset, [])
            }
            consumedText = String(text[...lastNewline])
            text = String(text[..<lastNewline])
        }

        let consumedBytes = UInt64(consumedText.data(using: .utf8)?.count ?? 0)
        let newOffset = readOffset + consumedBytes
        let events = rolloutEvents(fromLines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        return (newOffset, events)
    }

    nonisolated static func rolloutEvents(fromLines lines: [String]) -> [RolloutMetricEvent] {
        var callStarts: [String: TimeInterval] = [:]
        var currentTurnID: String?
        return suppressDuplicateVisibleMessages(
            lines.enumerated().flatMap { lineIndex, line in
                if let turnID = rolloutTurnID(fromLine: line) {
                    currentTurnID = turnID
                }
                return rolloutEvents(fromLine: line, callStarts: &callStarts, currentTurnID: currentTurnID).map { event in
                    guard event.category == .visibleText, event.itemID == nil else { return event }
                    return RolloutMetricEvent(
                        timestamp: event.timestamp,
                        startTimestamp: event.startTimestamp,
                        key: "\(event.key):line:\(lineIndex)",
                        turnID: event.turnID,
                        itemID: nil,
                        category: event.category,
                        text: event.text,
                        exactTokens: event.exactTokens,
                        exactOutputTokens: event.exactOutputTokens,
                        rollingOnly: event.rollingOnly
                    )
                }
            }
        )
    }

    nonisolated static func rolloutEvents(fromLine line: String) -> [RolloutMetricEvent] {
        var callStarts: [String: TimeInterval] = [:]
        return rolloutEvents(fromLine: line, callStarts: &callStarts, currentTurnID: rolloutTurnID(fromLine: line))
    }

    nonisolated static func rolloutEvents(
        fromLine line: String,
        callStarts: inout [String: TimeInterval],
        currentTurnID: String? = nil
    ) -> [RolloutMetricEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return []
        }

        guard let timestamp = parseTimestamp(object["timestamp"] as? String) else {
            return []
        }
        let recordType = object["type"] as? String
        let payloadType = payload["type"] as? String
        let keyPrefix = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString
        let turnID = rolloutTurnID(object: object, payload: payload) ?? currentTurnID

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
                    key: "agent:\(timestamp):\(text.hashValue)",
                    turnID: turnID,
                    itemID: nil,
                    category: .visibleText,
                    text: text
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
                    turnID: turnID,
                    itemID: payload["id"] as? String,
                    category: .visibleText,
                    text: text
                )
            ]
        }

        if recordType == "response_item", payloadType == "function_call_output" {
            return []
        }

        if recordType == "response_item", payloadType == "custom_tool_call_output" {
            return []
        }

        if recordType == "event_msg", payloadType == "patch_apply_end" {
            return []
        }

        if recordType == "event_msg", payloadType == "token_count" {
            return []
        }

        return []
    }

    nonisolated private static func suppressDuplicateVisibleMessages(_ events: [RolloutMetricEvent]) -> [RolloutMetricEvent] {
        var seen: [(event: RolloutMetricEvent, timestamp: TimeInterval)] = []
        return events.filter { event in
            guard event.category == .visibleText, !event.text.isEmpty else { return true }
            let duplicatePairIndex = seen.firstIndex { previous in
                guard event.timestamp - previous.timestamp <= 10,
                      event.text == previous.event.text,
                      event.turnID == previous.event.turnID
                else { return false }
                return (event.itemID == nil) != (previous.event.itemID == nil)
            }
            if let duplicatePairIndex {
                seen.remove(at: duplicatePairIndex)
                return false
            }
            seen.append((event, event.timestamp))
            seen.removeAll { event.timestamp - $0.timestamp > 10 }
            return true
        }
    }

    nonisolated private static func rolloutTurnID(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return rolloutTurnID(object: object, payload: payload)
    }

    nonisolated private static func rolloutTurnID(object: [String: Any], payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String, !turnID.isEmpty { return turnID }
        if let turnID = object["turn_id"] as? String, !turnID.isEmpty { return turnID }
        if let metadata = payload["metadata"] as? [String: Any],
           let turnID = metadata["turn_id"] as? String,
           !turnID.isEmpty { return turnID }
        return nil
    }

    nonisolated static func parseTimestamp(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        guard let date = fractionalFormatter.date(from: text) ?? fallbackFormatter.date(from: text) else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    nonisolated static func sqliteScalarInt(db: String, sql: String, bindings: [SQLiteBinding] = []) throws -> Int {
        try sqliteRows(db: db, sql: sql, bindings: bindings) { statement in
            sqliteInt(statement, 0)
        }.first ?? 0
    }

    nonisolated static func sqliteRows<T>(
        db path: String,
        sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: path),
            readOnly: true,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.readRows(sql, bindings: bindings, map: map)
    }

    nonisolated static func sqliteText(_ statement: SQLiteStatement, _ column: Int32) -> String? {
        statement.text(column)
    }

    nonisolated static func sqliteInt(_ statement: SQLiteStatement, _ column: Int32) -> Int {
        statement.int(column) ?? 0
    }
}
