import Foundation
import Darwin
import CryptoKit

extension LiveRateMonitor {
    nonisolated static let rolloutTurnContextBackscanByteLimit: UInt64 = 64 * 1_024
    nonisolated static let rolloutBoundarySignatureByteLimit: UInt64 = 256

    nonisolated static func rolloutReads(
        options: [LiveThreadOption],
        states: [String: RolloutReadState]
    ) throws -> [RolloutRead] {
        try options.compactMap { option in
            guard let path = option.normalizedRolloutPath else { return nil }
            let state = states[path] ?? initialRolloutReadState(path: path)
            let result = try rolloutEvents(path: path, state: state)
            return RolloutRead(
                threadID: option.id,
                path: path,
                newOffset: result.state.offset,
                events: result.events,
                currentTurnID: result.state.currentTurnID,
                fileIdentity: result.state.fileIdentity,
                boundarySignature: result.state.boundarySignature,
                discardLeadingPartialLine: result.state.discardLeadingPartialLine
            )
        }
    }

    nonisolated static func rolloutEvents(
        path: String,
        state: RolloutReadState
    ) throws -> (state: RolloutReadState, events: [RolloutMetricEvent]) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (RolloutReadState(offset: 0, currentTurnID: nil, fileIdentity: nil), [])
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let metadata = try rolloutFileMetadata(handle: handle)
        let boundaryChanged: Bool
        if metadata.size >= state.offset, let expected = state.boundarySignature {
            boundaryChanged = try rolloutBoundarySignature(handle: handle, endingAt: state.offset) != expected
        } else {
            boundaryChanged = false
        }
        let restarted = metadata.size < state.offset
            || state.fileIdentity.map { $0 != metadata.identity } == true
            || boundaryChanged
        let readOffset = restarted ? 0 : state.offset
        let previousTurnID = restarted ? nil : state.currentTurnID
        var discardLeadingPartialLine = restarted ? false : state.discardLeadingPartialLine
        if metadata.size == readOffset {
            return (
                try rolloutReadState(
                    handle: handle,
                    offset: metadata.size,
                    currentTurnID: previousTurnID,
                    fileIdentity: metadata.identity,
                    discardLeadingPartialLine: discardLeadingPartialLine
                ),
                []
            )
        }
        try handle.seek(toOffset: readOffset)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else {
            return (
                try rolloutReadState(
                    handle: handle,
                    offset: readOffset,
                    currentTurnID: previousTurnID,
                    fileIdentity: metadata.identity,
                    discardLeadingPartialLine: discardLeadingPartialLine
                ),
                []
            )
        }

        var skippedByteCount = 0
        if discardLeadingPartialLine {
            guard let firstNewline = data.firstIndex(of: 0x0A) else {
                return (
                    try rolloutReadState(
                        handle: handle,
                        offset: readOffset,
                        currentTurnID: previousTurnID,
                        fileIdentity: metadata.identity,
                        discardLeadingPartialLine: true
                    ),
                    []
                )
            }
            skippedByteCount = data.distance(from: data.startIndex, to: data.index(after: firstNewline))
            discardLeadingPartialLine = false
        }

        let remaining = data.dropFirst(skippedByteCount)
        guard let lastNewline = remaining.lastIndex(of: 0x0A) else {
            let newOffset = readOffset + UInt64(skippedByteCount)
            return (
                try rolloutReadState(
                    handle: handle,
                    offset: newOffset,
                    currentTurnID: previousTurnID,
                    fileIdentity: metadata.identity,
                    discardLeadingPartialLine: false
                ),
                []
            )
        }
        let completeEnd = remaining.index(after: lastNewline)
        let completeByteCount = remaining.distance(from: remaining.startIndex, to: completeEnd)
        let completeData = Data(remaining[..<completeEnd])
        guard let text = String(data: completeData, encoding: .utf8) else {
            let newOffset = readOffset + UInt64(skippedByteCount)
            return (
                try rolloutReadState(
                    handle: handle,
                    offset: newOffset,
                    currentTurnID: previousTurnID,
                    fileIdentity: metadata.identity,
                    discardLeadingPartialLine: false
                ),
                []
            )
        }

        let newOffset = readOffset + UInt64(skippedByteCount + completeByteCount)
        let parsed = rolloutEvents(
            fromLines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
            previousTurnID: previousTurnID
        )
        return (
            try rolloutReadState(
                handle: handle,
                offset: newOffset,
                currentTurnID: parsed.currentTurnID,
                fileIdentity: metadata.identity,
                discardLeadingPartialLine: false
            ),
            parsed.events
        )
    }

    nonisolated static func initialRolloutReadState(path: String) -> RolloutReadState {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return RolloutReadState(offset: 0, currentTurnID: nil, fileIdentity: nil)
        }
        defer { try? handle.close() }
        guard let metadata = try? rolloutFileMetadata(handle: handle) else {
            return RolloutReadState(offset: 0, currentTurnID: nil, fileIdentity: nil)
        }
        return (try? initialRolloutReadState(handle: handle, metadata: metadata))
            ?? RolloutReadState(offset: metadata.size, currentTurnID: nil, fileIdentity: metadata.identity)
    }

    nonisolated static func rolloutReadState(
        path: String,
        offset: UInt64,
        currentTurnID: String?
    ) -> RolloutReadState {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return RolloutReadState(offset: offset, currentTurnID: currentTurnID, fileIdentity: nil)
        }
        defer { try? handle.close() }
        guard let metadata = try? rolloutFileMetadata(handle: handle), metadata.size >= offset else {
            return RolloutReadState(offset: offset, currentTurnID: currentTurnID, fileIdentity: nil)
        }
        return (try? rolloutReadState(
            handle: handle,
            offset: offset,
            currentTurnID: currentTurnID,
            fileIdentity: metadata.identity,
            discardLeadingPartialLine: false
        )) ?? RolloutReadState(
            offset: offset,
            currentTurnID: currentTurnID,
            fileIdentity: metadata.identity
        )
    }

    nonisolated static func rolloutEvents(fromLines lines: [String]) -> [RolloutMetricEvent] {
        rolloutEvents(fromLines: lines, previousTurnID: nil).events
    }

    nonisolated static func rolloutEvents(
        fromLines lines: [String],
        previousTurnID: String?
    ) -> (events: [RolloutMetricEvent], currentTurnID: String?) {
        var callStarts: [String: TimeInterval] = [:]
        var currentTurnID = previousTurnID
        let events = suppressDuplicateVisibleMessages(
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
        return (events, currentTurnID)
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

    nonisolated private static func initialRolloutReadState(
        handle: FileHandle,
        metadata: (size: UInt64, identity: RolloutFileIdentity)
    ) throws -> RolloutReadState {
        let tailByteCount = min(metadata.size, rolloutTurnContextBackscanByteLimit)
        let tailOffset = metadata.size - tailByteCount
        try handle.seek(toOffset: tailOffset)
        let tailData = try handle.read(upToCount: Int(tailByteCount)) ?? Data()
        let bytes = Array(tailData)
        let completeEnd: Int
        if bytes.last == 0x0A {
            completeEnd = bytes.count
        } else if let lastNewline = bytes.lastIndex(of: 0x0A) {
            completeEnd = lastNewline + 1
        } else {
            completeEnd = 0
        }

        guard completeEnd > 0 else {
            let offset = tailOffset == 0 ? 0 : tailOffset
            return try rolloutReadState(
                handle: handle,
                offset: offset,
                currentTurnID: nil,
                fileIdentity: metadata.identity,
                discardLeadingPartialLine: tailOffset > 0
            )
        }

        let parseStart: Int
        if tailOffset == 0 {
            parseStart = 0
        } else {
            parseStart = (bytes.firstIndex(of: 0x0A) ?? -1) + 1
        }
        let currentTurnID: String?
        if parseStart < completeEnd,
           let text = String(data: Data(bytes[parseStart..<completeEnd]), encoding: .utf8) {
            currentTurnID = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
                .compactMap { rolloutTurnContextID(fromLine: String($0)) }
                .first
        } else {
            currentTurnID = nil
        }
        return try rolloutReadState(
            handle: handle,
            offset: tailOffset + UInt64(completeEnd),
            currentTurnID: currentTurnID,
            fileIdentity: metadata.identity,
            discardLeadingPartialLine: false
        )
    }

    nonisolated private static func rolloutTurnContextID(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              object["type"] as? String == "turn_context"
                || payload["type"] as? String == "turn_context"
        else { return nil }
        return rolloutTurnID(object: object, payload: payload)
    }

    nonisolated private static func rolloutReadState(
        handle: FileHandle,
        offset: UInt64,
        currentTurnID: String?,
        fileIdentity: RolloutFileIdentity,
        discardLeadingPartialLine: Bool
    ) throws -> RolloutReadState {
        RolloutReadState(
            offset: offset,
            currentTurnID: currentTurnID,
            fileIdentity: fileIdentity,
            boundarySignature: try rolloutBoundarySignature(handle: handle, endingAt: offset),
            discardLeadingPartialLine: discardLeadingPartialLine
        )
    }

    nonisolated private static func rolloutBoundarySignature(
        handle: FileHandle,
        endingAt offset: UInt64
    ) throws -> RolloutBoundarySignature {
        let requestedByteCount = min(offset, rolloutBoundarySignatureByteLimit)
        try handle.seek(toOffset: offset - requestedByteCount)
        let data = try handle.read(upToCount: Int(requestedByteCount)) ?? Data()
        return RolloutBoundarySignature(
            sampledByteCount: data.count,
            sha256: Array(SHA256.hash(data: data))
        )
    }

    nonisolated private static func rolloutFileMetadata(
        handle: FileHandle
    ) throws -> (size: UInt64, identity: RolloutFileIdentity) {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (
            UInt64(max(0, info.st_size)),
            RolloutFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        )
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
