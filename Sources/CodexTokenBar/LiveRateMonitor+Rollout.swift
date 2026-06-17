import Foundation

extension LiveRateMonitor {
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
