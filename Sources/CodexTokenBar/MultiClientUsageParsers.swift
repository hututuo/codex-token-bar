import CoreFoundation
import CryptoKit
import Foundation

enum MultiClientUsageParserError: Error, Equatable {
    case inputTooLarge
}

/// Parses only locally stored usage records. Transcript text and prompt contents are ignored.
enum MultiClientUsageParsers {
    static let maximumInputBytes = 16 * 1_024 * 1_024
    static let maximumOpenCodePageSize = 500
    private static let maximumOpenCodeRowBytes = 64 * 1_024

    private typealias Object = [String: Any]

    private enum CountValue {
        case missing
        case value(Int64)
        case invalid

        var intValue: Int64? {
            if case .value(let value) = self { value } else { nil }
        }
    }

    private struct TokenFields {
        var input: Int64?
        var output: Int64?
        var cacheRead: Int64?
        var cacheWrite: Int64?
        var reasoning: Int64?

        var hasAny: Bool {
            input != nil || output != nil || cacheRead != nil || cacheWrite != nil || reasoning != nil
        }
    }

    /// Parses one JSON document, an array of JSON objects, or complete JSONL records. An unfinished final JSONL
    /// record is ignored so a caller can pass a byte-aligned incremental tail on its next scan.
    static func parse(data: Data, client: UsageClient, sessionHint: String) throws -> [ClientUsageEvent] {
        guard data.count <= maximumInputBytes else { throw MultiClientUsageParserError.inputTooLarge }
        guard !data.isEmpty else { return [] }

        if let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return deduplicated(parseRoot(root, client: client, sessionHint: sessionHint))
        }

        // The root scanner supplies complete newline-delimited records. Keep the same rule here for callers that
        // provide several lines plus a partial final record.
        guard let finalNewline = data.lastIndex(of: 0x0A) else { return [] }
        let completePrefix = data[..<data.index(after: finalNewline)]
        var parsed: [ClientUsageEvent] = []
        var currentSession = sessionHint
        for rawLine in completePrefix.split(separator: 0x0A, omittingEmptySubsequences: true) {
            var line = Data(rawLine)
            if line.last == 0x0D { line.removeLast() }
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
            guard !line.isEmpty,
                  let root = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
            else { continue }
            if client == .deepseek, let header = deepSeekHeaderSession(root) { currentSession = header }
            parsed.append(contentsOf: parseRoot(root, client: client, sessionHint: currentSession))
        }
        return deduplicated(parsed)
    }

    /// Reads one bounded, keyset-paginated page of OpenCode assistant/compaction rows. The ordering is stable for
    /// unchanged rows, and the caller can continue until `isComplete` becomes true. It does not create or modify
    /// the database or its sidecars.
    static func readOpenCodeDatabase(
        url: URL,
        after cursor: OpenCodeDatabaseCursor? = nil,
        limit requestedLimit: Int = maximumOpenCodePageSize
    ) throws -> OpenCodeDatabasePage {
        let limit = min(max(requestedLimit, 1), maximumOpenCodePageSize)
        let database = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: 500
        )
        let base = """
            SELECT m.id, m.session_id, m.type, m.time_created, m.time_updated,
                   CASE WHEN length(CAST(m.data AS BLOB)) <= \(maximumOpenCodeRowBytes) THEN m.data ELSE NULL END,
                   length(CAST(m.data AS BLOB)), s.time_created
            FROM session_message AS m
            LEFT JOIN session_v2 AS s ON s.id = m.session_id
            """
        let sql: String
        let bindings: [SQLiteBinding]
        if let cursor {
            sql = base + "\n" + """
                WHERE m.time_updated > ?1 OR (m.time_updated = ?1 AND m.id COLLATE BINARY > ?2)
                ORDER BY m.time_updated ASC, m.id COLLATE BINARY ASC
                LIMIT \(limit + 1)
                """
            bindings = [.int64(cursor.updatedAtMilliseconds), .text(cursor.messageID)]
        } else {
            sql = base + "\n" + """
                ORDER BY m.time_updated ASC, m.id COLLATE BINARY ASC
                LIMIT \(limit + 1)
                """
            bindings = []
        }
        let rows: [OpenCodeRawRow] = try database.readRows(sql, bindings: bindings) { row in
            OpenCodeRawRow(
                id: row.text(0),
                sessionID: row.text(1),
                type: row.text(2),
                createdMilliseconds: row.int64(3),
                updatedMilliseconds: row.int64(4),
                data: row.text(5),
                dataByteCount: row.int64(6) ?? 0,
                sessionCreatedMilliseconds: row.int64(7)
            )
        }

        let isComplete = rows.count <= limit
        let consumedRows = Array(rows.prefix(limit))
        var events: [ClientUsageEvent] = []
        var malformed = 0
        var oversized = 0
        for row in consumedRows {
            if row.dataByteCount > Int64(maximumOpenCodeRowBytes) {
                oversized += 1
                continue
            }
            guard let id = row.id,
                  let sessionID = row.sessionID,
                  let type = row.type,
                  let dataString = row.data,
                  let dataBytes = dataString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: dataBytes) as? Object
            else {
                malformed += 1
                continue
            }
            if let event = openCodeEvent(
                id: id,
                sessionID: sessionID,
                type: type,
                rowCreatedMs: row.createdMilliseconds,
                rowUpdatedMs: row.updatedMilliseconds,
                sessionCreatedMs: row.sessionCreatedMilliseconds,
                data: object
            ) {
                events.append(event)
            }
        }
        let nextCursor: OpenCodeDatabaseCursor? = consumedRows.last.flatMap { row -> OpenCodeDatabaseCursor? in
            guard let id = row.id, let updatedAt = row.updatedMilliseconds else { return nil }
            return OpenCodeDatabaseCursor(updatedAtMilliseconds: updatedAt, messageID: id)
        }
        return OpenCodeDatabasePage(
            events: deduplicated(events).sorted(by: eventOrder),
            nextCursor: nextCursor,
            isComplete: isComplete,
            skippedMalformedRows: malformed,
            skippedOversizedRows: oversized
        )
    }

    private struct OpenCodeRawRow {
        var id: String?
        var sessionID: String?
        var type: String?
        var createdMilliseconds: Int64?
        var updatedMilliseconds: Int64?
        var data: String?
        var dataByteCount: Int64
        var sessionCreatedMilliseconds: Int64?
    }

    private static func parseRoot(_ root: Any, client: UsageClient, sessionHint: String) -> [ClientUsageEvent] {
        switch client {
        case .claudeCode, .claudeDesktop:
            return objects(in: root).compactMap { claudeEvent($0, client: client, sessionHint: sessionHint) }
        case .deepseek:
            var flattened: [(object: Object, inheritedTimeMs: Int64?, sessionID: String?)] = []
            flattenDeepSeek(root, inheritedTimeMs: nil, inheritedSessionID: nil, into: &flattened)
            return flattened.compactMap { record in
                deepSeekEvent(
                    record.object,
                    inheritedTimeMs: record.inheritedTimeMs,
                    headerSessionID: record.sessionID,
                    sessionHint: sessionHint
                )
            }
        case .gemini:
            var messages: [(object: Object, documentSessionID: String?)] = []
            collectGeminiMessages(root, documentSessionID: nil, into: &messages)
            return messages.compactMap {
                geminiEvent($0.object, documentSessionID: $0.documentSessionID, sessionHint: sessionHint)
            }
        case .opencode:
            var rows: [Object] = []
            collectOpenCodeRows(root, into: &rows)
            return rows.compactMap { openCodeJSONEvent($0, sessionHint: sessionHint) }
        }
    }

    // MARK: Claude Code and local Claude Desktop transcripts

    private static func claudeEvent(_ object: Object, client: UsageClient, sessionHint: String) -> ClientUsageEvent? {
        guard object["type"] as? String == "assistant" else { return nil }
        // Source is established by file discovery from the first entrypoint-bearing record. Later JSONL chunks
        // often omit entrypoint, so trust the caller's file classification for those records.
        if let entrypoint = nonEmptyString(object["entrypoint"]) {
            let isDesktopRecord = entrypoint.hasPrefix("claude-desktop")
            guard (client == .claudeDesktop) == isDesktopRecord else { return nil }
        }

        guard let message = object["message"] as? Object,
              nonEmptyString(message["model"]) != "<synthetic>",
              let usage = message["usage"] as? Object,
              let fields = tokenFields(
                usage,
                inputKey: "input_tokens",
                outputKey: "output_tokens",
                cacheReadKey: "cache_read_input_tokens",
                cacheWriteKey: "cache_creation_input_tokens",
                reasoningKey: "output_tokens_details.thinking_tokens"
              ),
              let timestamp = date(object["timestamp"])
        else { return nil }

        let sessionID = nonEmptyString(object["sessionId"]) ?? nonEmptyString(sessionHint) ?? "unknown-session"
        let messageID = nonEmptyString(message["id"])
            ?? nonEmptyString(object["requestId"])
            ?? nonEmptyString(object["uuid"])
        let model = nonEmptyString(message["model"]) ?? "unknown"
        let input = saturatedSum(fields.input ?? 0, fields.cacheRead ?? 0, fields.cacheWrite ?? 0)
        return makeEvent(
            client: client,
            sessionID: sessionID,
            identity: messageID.map { .sourceID($0) },
            model: model,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: fields.output ?? 0,
            cacheReadTokens: fields.cacheRead,
            cacheWriteTokens: fields.cacheWrite,
            reasoningTokens: fields.reasoning
        )
    }

    // MARK: DeepSeek Harness / DSH

    static func deepSeekHeaderSession(_ root: Any) -> String? {
        guard let object = root as? Object else { return nil }
        if object["type"] as? String == "session" { return nonEmptyString(object["id"]) }
        if object["type"] as? String == "snapshot" { return nonEmptyString((object["header"] as? Object)?["id"]) }
        return nil
    }

    static func deepSeekHeaderSession(data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data), let session = deepSeekHeaderSession(root) { return session }
        for line in data.split(separator: 10) {
            if let root = try? JSONSerialization.jsonObject(with: Data(line)), let session = deepSeekHeaderSession(root) { return session }
        }
        return nil
    }

    private enum EventIdentity {
        case sourceID(String)
        case sequence(Int64)
    }

    private static func flattenDeepSeek(
        _ value: Any,
        inheritedTimeMs: Int64?,
        inheritedSessionID: String?,
        into records: inout [(object: Object, inheritedTimeMs: Int64?, sessionID: String?)]
    ) {
        if let array = value as? [Any] {
            for item in array {
                flattenDeepSeek(item, inheritedTimeMs: inheritedTimeMs, inheritedSessionID: inheritedSessionID, into: &records)
            }
            return
        }
        guard let object = value as? Object else { return }

        let type = object["type"] as? String
        let time = milliseconds(object["time"]) ?? inheritedTimeMs
        let ownSession = nonEmptyString(object["sessionId"]) ?? inheritedSessionID
        if type == "snapshot" {
            let header = object["header"] as? Object
            let session = nonEmptyString(header?["id"]) ?? ownSession
            if let recordsValue = object["records"] {
                flattenDeepSeek(recordsValue, inheritedTimeMs: time, inheritedSessionID: session, into: &records)
            }
            return
        }
        if type == "event" {
            if let event = object["event"] {
                flattenDeepSeek(event, inheritedTimeMs: time, inheritedSessionID: ownSession, into: &records)
            }
            return
        }
        if type == "assistant/message" {
            records.append((object, time, ownSession))
            return
        }
        if let recordsValue = object["records"] {
            flattenDeepSeek(recordsValue, inheritedTimeMs: time, inheritedSessionID: ownSession, into: &records)
        }
    }

    private static func deepSeekEvent(
        _ object: Object,
        inheritedTimeMs: Int64?,
        headerSessionID: String?,
        sessionHint: String
    ) -> ClientUsageEvent? {
        let data = object["data"] as? Object ?? [:]
        let message = data["message"] as? Object ?? [:]
        let usage = data["usage"] as? Object ?? message["usage"] as? Object
        guard let usage,
              let fields = tokenFields(
                usage,
                inputKey: "inputTokens",
                outputKey: "outputTokens",
                cacheReadKey: "cacheReadTokens",
                cacheWriteKey: "cacheWriteTokens"
              ),
              let timestampMs = milliseconds(object["time"]) ?? inheritedTimeMs
        else { return nil }

        let sessionID = headerSessionID
            ?? nonEmptyString(object["sessionId"])
            ?? nonEmptyString(sessionHint)
            ?? "unknown-session"
        let messageID = nonEmptyString(message["id"])
        let sequence = integer(object["seq"])
        let identity: EventIdentity? = messageID.map(EventIdentity.sourceID)
            ?? sequence.map(EventIdentity.sequence)
        let source = message["source"] as? Object
        let model = nonEmptyString(source?["model"]) ?? "unknown"
        return makeEvent(
            client: .deepseek,
            sessionID: sessionID,
            identity: identity,
            model: model,
            timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000),
            inputTokens: saturatedSum(fields.input ?? 0, fields.cacheRead ?? 0, fields.cacheWrite ?? 0),
            outputTokens: fields.output ?? 0,
            cacheReadTokens: fields.cacheRead,
            cacheWriteTokens: fields.cacheWrite,
            reasoningTokens: nil
        )
    }

    // MARK: Gemini CLI

    private static func collectGeminiMessages(
        _ value: Any,
        documentSessionID: String?,
        into messages: inout [(object: Object, documentSessionID: String?)]
    ) {
        if let array = value as? [Any] {
            for item in array { collectGeminiMessages(item, documentSessionID: documentSessionID, into: &messages) }
            return
        }
        guard let object = value as? Object else { return }
        let rootSession = nonEmptyString(object["sessionId"]) ?? documentSessionID

        if object["type"] as? String == "gemini" {
            messages.append((object, rootSession))
            return
        }
        if let ordinaryMessages = object["messages"] as? [Any] {
            for item in ordinaryMessages { collectGeminiMessages(item, documentSessionID: rootSession, into: &messages) }
        }
        if let set = object["$set"] as? Object,
           let checkpoint = set["messages"] as? Object,
           let checkpointMessages = checkpoint["messages"] as? [Any] {
            for item in checkpointMessages { collectGeminiMessages(item, documentSessionID: rootSession, into: &messages) }
        } else if let set = object["$set"] as? Object,
                  let checkpointMessages = set["messages"] as? [Any] {
            for item in checkpointMessages { collectGeminiMessages(item, documentSessionID: rootSession, into: &messages) }
        }
    }

    private static func geminiEvent(
        _ object: Object,
        documentSessionID: String?,
        sessionHint: String
    ) -> ClientUsageEvent? {
        guard object["type"] as? String == "gemini",
              let tokens = object["tokens"] as? Object,
              let fields = tokenFields(
                tokens,
                inputKey: "input",
                outputKey: "output",
                cacheReadKey: "cached",
                reasoningKey: "thoughts",
                additionalInputKey: "tool"
              ),
              let timestamp = date(object["timestamp"])
        else { return nil }

        let sessionID = nonEmptyString(object["sessionId"])
            ?? documentSessionID
            ?? nonEmptyString(sessionHint)
            ?? "unknown-session"
        return makeEvent(
            client: .gemini,
            sessionID: sessionID,
            identity: nonEmptyString(object["id"]).map(EventIdentity.sourceID),
            model: nonEmptyString(object["model"]) ?? "unknown",
            timestamp: timestamp,
            inputTokens: fields.input ?? 0,
            outputTokens: saturatedSum(fields.output ?? 0, fields.reasoning ?? 0),
            cacheReadTokens: fields.cacheRead,
            cacheWriteTokens: nil,
            reasoningTokens: fields.reasoning
        )
    }

    // MARK: OpenCode JSON and SQLite records

    private static func collectOpenCodeRows(_ value: Any, into rows: inout [Object]) {
        if let array = value as? [Any] {
            for item in array { collectOpenCodeRows(item, into: &rows) }
            return
        }
        guard let object = value as? Object else { return }
        if let messages = object["messages"] as? [Any] {
            for message in messages { collectOpenCodeRows(message, into: &rows) }
            return
        }
        if let message = object["message"] as? Object {
            collectOpenCodeRows(message, into: &rows)
            return
        }
        rows.append(object)
    }

    private static func openCodeJSONEvent(_ object: Object, sessionHint: String) -> ClientUsageEvent? {
        let data = object["data"] as? Object ?? object
        return openCodeEvent(
            id: nonEmptyString(object["id"]),
            sessionID: nonEmptyString(object["session_id"])
                ?? nonEmptyString(object["sessionID"])
                ?? nonEmptyString(object["sessionId"])
                ?? nonEmptyString(data["sessionID"])
                ?? nonEmptyString(sessionHint)
                ?? "unknown-session",
            type: object["type"] as? String ?? object["role"] as? String ?? "assistant",
            rowCreatedMs: milliseconds(data["time"].flatMap { ($0 as? Object)?["created"] })
                ?? milliseconds(object["time_created"]),
            rowUpdatedMs: milliseconds(object["time_updated"]),
            sessionCreatedMs: milliseconds(object["session_created"]),
            data: data
        )
    }

    private static func openCodeEvent(
        id: String?,
        sessionID: String,
        type: String,
        rowCreatedMs: Int64?,
        rowUpdatedMs: Int64?,
        sessionCreatedMs: Int64?,
        data: Object
    ) -> ClientUsageEvent? {
        guard type == "assistant" || type == "compaction" else { return nil }
        let time = data["time"] as? Object ?? [:]
        let messageCreatedMs = milliseconds(time["created"])
        let createdMs = messageCreatedMs ?? rowCreatedMs
        if type == "assistant", let messageCreatedMs, let sessionCreatedMs,
           messageCreatedMs < sessionCreatedMs - 2_000 {
            return nil // OpenCode copies parent messages when a session is forked.
        }
        if type == "assistant", milliseconds(time["streamed"]) == nil,
           milliseconds(time["completed"]) == nil {
            return nil // An assistant row without a completion timestamp may still be streaming.
        }

        let candidateTimestamp = milliseconds(
            type == "assistant" ? (time["streamed"] ?? time["completed"]) : time["completed"]
        ) ?? date(data["timestamp"]).map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
            ?? rowUpdatedMs ?? createdMs
        guard let tokens = data["tokens"] as? Object,
              let fields = tokenFields(
                tokens,
                inputKey: "input",
                outputKey: "output",
                cacheReadKey: "cache.read",
                cacheWriteKey: "cache.write",
                reasoningKey: "reasoning"
              ),
              let timestampMs = candidateTimestamp
        else { return nil }

        let modelObject = data["model"] as? Object
        let model = nonEmptyString(modelObject?["id"])
            ?? nonEmptyString(data["model"] as? String)
            ?? nonEmptyString(data["modelID"])
            ?? "unknown"
        return makeEvent(
            client: .opencode,
            sessionID: sessionID,
            identity: id.map(EventIdentity.sourceID),
            model: model,
            timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1_000),
            inputTokens: saturatedSum(fields.input ?? 0, fields.cacheRead ?? 0, fields.cacheWrite ?? 0),
            outputTokens: saturatedSum(fields.output ?? 0, fields.reasoning ?? 0),
            cacheReadTokens: fields.cacheRead,
            cacheWriteTokens: fields.cacheWrite,
            reasoningTokens: fields.reasoning
        )
    }

    private static func objects(in value: Any) -> [Object] {
        if let object = value as? Object { return [object] }
        if let array = value as? [Any] { return array.flatMap(objects(in:)) }
        return []
    }

    // MARK: Normalization and identity

    private static func tokenFields(
        _ object: Object,
        inputKey: String,
        outputKey: String,
        cacheReadKey: String? = nil,
        cacheWriteKey: String? = nil,
        reasoningKey: String? = nil,
        additionalInputKey: String? = nil
    ) -> TokenFields? {
        let input = count(object, keyPath: inputKey)
        let output = count(object, keyPath: outputKey)
        let cacheRead = cacheReadKey.map { count(object, keyPath: $0) } ?? .missing
        let cacheWrite = cacheWriteKey.map { count(object, keyPath: $0) } ?? .missing
        let reasoning = reasoningKey.map { count(object, keyPath: $0) } ?? .missing
        let additionalInput = additionalInputKey.map { count(object, keyPath: $0) } ?? .missing
        let all = [input, output, cacheRead, cacheWrite, reasoning, additionalInput]
        guard !all.contains(where: { if case .invalid = $0 { true } else { false } }) else { return nil }

        let fields = TokenFields(
            input: input.intValue,
            output: output.intValue,
            cacheRead: cacheRead.intValue,
            cacheWrite: cacheWrite.intValue,
            reasoning: reasoning.intValue
        )
        guard fields.hasAny || additionalInput.intValue != nil else { return nil }
        if case .value(let extra) = additionalInput {
            return TokenFields(
                input: saturatedSum(fields.input ?? 0, extra),
                output: fields.output,
                cacheRead: fields.cacheRead,
                cacheWrite: fields.cacheWrite,
                reasoning: fields.reasoning
            )
        }
        return fields
    }

    private static func count(_ object: Object, keyPath: String) -> CountValue {
        let components = keyPath.split(separator: ".")
        var value: Any? = object
        for component in components {
            value = (value as? Object)?[String(component)]
        }
        guard let value else { return .missing }
        if value is NSNull { return .missing }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return .invalid }
        let raw = number.stringValue
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let integer = Int64(raw)
        else { return .invalid }
        return .value(min(integer, ClientUsageEvent.maximumTokenCount))
    }

    private static func makeEvent(
        client: UsageClient,
        sessionID: String,
        identity: EventIdentity?,
        model: String,
        timestamp: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64?,
        cacheWriteTokens: Int64?,
        reasoningTokens: Int64?
    ) -> ClientUsageEvent {
        let timeMs = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        let sessionHash = sha256Hex(Data(sessionID.utf8))
        let identityPart: String
        let quality: String
        switch identity {
        case .sourceID(let value)?:
            identityPart = "id:" + sha256Hex(Data(value.utf8))
            quality = "recorded"
        case .sequence(let value)?:
            identityPart = "seq:\(value)"
            quality = "recorded"
        case nil:
            let normalizedCacheRead: String = cacheReadTokens.map { String($0) } ?? "-"
            let normalizedCacheWrite: String = cacheWriteTokens.map { String($0) } ?? "-"
            let normalizedReasoning: String = reasoningTokens.map { String($0) } ?? "-"
            var normalizedParts: [String] = []
            normalizedParts.reserveCapacity(8)
            normalizedParts.append(client.rawValue)
            normalizedParts.append(String(timeMs))
            normalizedParts.append(model)
            normalizedParts.append(String(inputTokens))
            normalizedParts.append(String(outputTokens))
            normalizedParts.append(normalizedCacheRead)
            normalizedParts.append(normalizedCacheWrite)
            normalizedParts.append(normalizedReasoning)
            let normalized = normalizedParts.joined(separator: "\u{1f}")
            identityPart = "fallback:" + sha256Hex(Data(normalized.utf8))
            quality = "fallback_identity"
        }
        return ClientUsageEvent(
            client: client,
            eventID: "v1:\(sessionHash):\(identityPart)",
            sessionID: sessionID,
            model: model,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            quality: quality
        )
    }

    private static func deduplicated(_ events: [ClientUsageEvent]) -> [ClientUsageEvent] {
        var positions: [String: Int] = [:]
        var merged: [ClientUsageEvent] = []
        for event in events {
            if let position = positions[event.eventID] {
                merged[position] = merged[position].mergingUpdate(event)
            } else {
                positions[event.eventID] = merged.count
                merged.append(event)
            }
        }
        return merged
    }

    private static func eventOrder(_ lhs: ClientUsageEvent, _ rhs: ClientUsageEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.eventID < rhs.eventID
    }

    private static func saturatedSum(_ values: Int64...) -> Int64 {
        values.reduce(Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? ClientUsageEvent.maximumTokenCount : min(sum, ClientUsageEvent.maximumTokenCount)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Scalar decoding

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let raw = number.stringValue
        guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int64(raw)
    }

    private static func milliseconds(_ value: Any?) -> Int64? {
        guard let integer = integer(value) else { return nil }
        return integer
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: string) { return parsed }
            let ordinary = ISO8601DateFormatter()
            ordinary.formatOptions = [.withInternetDateTime]
            return ordinary.date(from: string)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let seconds = number.doubleValue >= 100_000_000_000
            ? number.doubleValue / 1_000
            : number.doubleValue
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
