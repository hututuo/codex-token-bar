import Foundation
import Darwin
import CryptoKit

extension LiveRateMonitor {
    nonisolated static let rolloutTurnContextBackscanByteLimit: UInt64 = 64 * 1_024
    nonisolated static let rolloutBoundarySignatureByteLimit: UInt64 = 256
    private nonisolated static let rolloutReadChunkBytes = 256 * 1_024

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
                cacheSamples: (state.initialCacheContextReset && !result.cacheReset
                    ? [CacheUsageSample(timestamp: 0, reset: true)]
                    : state.initialCacheContextEstablished && !result.cacheReset
                        ? [CacheUsageSample(timestamp: 0, establishedContext: true)] : []) + result.cacheSamples,
                cacheReset: result.cacheReset,
                initialCacheContextReset: result.state.initialCacheContextReset,
                initialCacheContextEstablished: result.state.initialCacheContextEstablished,
                telemetry: result.telemetry,
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
    ) throws -> (state: RolloutReadState, events: [RolloutMetricEvent], cacheSamples: [CacheUsageSample], cacheReset: Bool, telemetry: [ThroughputSignal]) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (RolloutReadState(offset: 0, currentTurnID: nil, fileIdentity: nil), [], [], true, [])
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path, isDirectory: false))
        defer { try? handle.close() }
        let metadata = try rolloutFileMetadata(handle: handle)
        let checkedBoundary: RolloutBoundarySignature? = if metadata.size >= state.offset, state.boundarySignature != nil {
            try rolloutBoundarySignature(handle: handle, endingAt: state.offset)
        } else {
            nil
        }
        let restarted = metadata.size < state.offset
            || state.fileIdentity.map { $0 != metadata.identity } == true
            || (checkedBoundary != nil && checkedBoundary != state.boundarySignature)
        let readOffset = restarted ? 0 : state.offset
        var discardLeadingPartialLine = restarted ? false : state.discardLeadingPartialLine
        var batch = RolloutEventBatch(currentTurnID: restarted ? nil : state.currentTurnID,
                                      includeCacheSamples: !restarted)
        let newOffset = try readCompleteRolloutLines(handle: handle, from: readOffset, through: metadata.size,
            discardLeadingPartialLine: &discardLeadingPartialLine) { batch.append($0) }
        let boundary = if newOffset == state.offset, !restarted, let checkedBoundary {
            checkedBoundary
        } else {
            try rolloutBoundarySignature(handle: handle, endingAt: newOffset)
        }
        var nextState = RolloutReadState(offset: newOffset, currentTurnID: batch.currentTurnID,
            fileIdentity: metadata.identity, boundarySignature: boundary,
            discardLeadingPartialLine: discardLeadingPartialLine)
        if restarted {
            let history = try initialRolloutReadState(handle: handle, metadata: metadata)
            nextState.initialCacheContextReset = history.initialCacheContextReset
            nextState.initialCacheContextEstablished = history.initialCacheContextEstablished
        }
        let parsed = batch.result()
        return (nextState, parsed.events, parsed.cacheSamples, restarted, parsed.telemetry)
    }

    /// Limit transient file storage to one chunk and one unfinished record.
    /// Only bytes through a newline advance the cursor; an append can finish
    /// the last record on the next poll without replaying the committed lines.
    nonisolated private static func readCompleteRolloutLines(
        handle: FileHandle, from offset: UInt64, through end: UInt64,
        discardLeadingPartialLine: inout Bool, consume: (Data) -> Void
    ) throws -> UInt64 {
        guard offset < end else { return offset }
        try handle.seek(toOffset: offset)
        var position = offset
        var committed = offset
        var unfinished = Data()
        while position < end {
            let amount = Int(min(end - position, UInt64(rolloutReadChunkBytes)))
            let chunk = try handle.readShared(upToCount: amount)
            guard !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                if discardLeadingPartialLine {
                    discardLeadingPartialLine = false
                } else if unfinished.isEmpty {
                    if start < newline { consume(chunk[start..<newline]) }
                } else {
                    unfinished.append(chunk[start..<newline])
                    consume(unfinished)
                    unfinished = Data()
                }
                start = chunk.index(after: newline)
                committed = position + UInt64(start - chunk.startIndex)
            }
            if !discardLeadingPartialLine { unfinished.append(chunk[start...]) }
            position += UInt64(chunk.count)
        }
        return committed
    }

    nonisolated static func initialRolloutReadState(path: String) -> RolloutReadState {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path, isDirectory: false)) else {
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
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path, isDirectory: false)) else {
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
        previousTurnID: String?, includeCacheSamples: Bool = true
    ) -> (events: [RolloutMetricEvent], currentTurnID: String?, cacheSamples: [CacheUsageSample], telemetry: [ThroughputSignal]) {
        var batch = RolloutEventBatch(currentTurnID: previousTurnID, includeCacheSamples: includeCacheSamples)
        for line in lines { batch.append(Data(line.utf8)) }
        return batch.result()
    }

    private struct RolloutEventBatch {
        var currentTurnID: String?
        let includeCacheSamples: Bool
        private var callStarts: [String: TimeInterval] = [:]
        private var events: [RolloutMetricEvent] = []
        private var cacheSamples: [CacheUsageSample] = []
        private var lineIndex = 0

        init(currentTurnID: String?, includeCacheSamples: Bool) {
            self.currentTurnID = currentTurnID
            self.includeCacheSamples = includeCacheSamples
        }

        mutating func append(_ data: Data) {
            let index = lineIndex
            lineIndex += 1
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any] else { return }
                if let turnID = rolloutTurnID(object: object, payload: payload) { currentTurnID = turnID }
                let parsed = rolloutEvents(object: object, payload: payload, callStarts: &callStarts,
                    currentTurnID: currentTurnID, cacheSamples: &cacheSamples, includeCacheSamples: includeCacheSamples)
                for event in parsed {
                    if event.category == .visibleText && event.itemID == nil {
                        events.append(RolloutMetricEvent(timestamp: event.timestamp, startTimestamp: event.startTimestamp,
                            key: "\(event.key):line:\(index)", turnID: event.turnID, itemID: nil, category: event.category,
                            text: event.text, exactTokens: event.exactTokens, exactOutputTokens: event.exactOutputTokens,
                            rollingOnly: event.rollingOnly))
                    } else {
                        events.append(event)
                    }
                }
            }
        }

        func result() -> (events: [RolloutMetricEvent], currentTurnID: String?,
                          cacheSamples: [CacheUsageSample], telemetry: [ThroughputSignal]) {
            let unique = suppressDuplicateVisibleMessages(events)
            return (unique.filter { $0.telemetry == nil }, currentTurnID, cacheSamples, unique.compactMap(\.telemetry))
        }
    }

    nonisolated static func rolloutEvents(fromLine line: String) -> [RolloutMetricEvent] {
        var callStarts: [String: TimeInterval] = [:]
        return rolloutEvents(fromLine: line, callStarts: &callStarts, currentTurnID: nil)
    }

    nonisolated static func rolloutEvents(
        fromLine line: String,
        callStarts: inout [String: TimeInterval],
        currentTurnID: String? = nil
    ) -> [RolloutMetricEvent] {
        var cacheSamples: [CacheUsageSample] = []
        return rolloutEvents(fromLine: line, callStarts: &callStarts, currentTurnID: currentTurnID, cacheSamples: &cacheSamples)
    }

    nonisolated static func rolloutEvents(
        fromLine line: String, callStarts: inout [String: TimeInterval], currentTurnID: String?,
        cacheSamples: inout [CacheUsageSample], includeCacheSamples: Bool = true
    ) -> [RolloutMetricEvent] {
        autoreleasepool {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else {
                return []
            }
            return rolloutEvents(object: object, payload: payload, callStarts: &callStarts,
                currentTurnID: currentTurnID, cacheSamples: &cacheSamples, includeCacheSamples: includeCacheSamples)
        }
    }

    nonisolated private static func rolloutEvents(
        object: [String: Any], payload: [String: Any], callStarts: inout [String: TimeInterval],
        currentTurnID: String?, cacheSamples: inout [CacheUsageSample], includeCacheSamples: Bool
    ) -> [RolloutMetricEvent] {
        let parsedTimestamp = parseTimestamp(object["timestamp"] as? String)
        if includeCacheSamples, let sample = CacheUsageSample.parse(object: object, payload: payload, timestamp: parsedTimestamp ?? .nan) {
            cacheSamples.append(sample)
        }
        guard let timestamp = parsedTimestamp else { return [] }
        let recordType = object["type"] as? String
        let payloadType = payload["type"] as? String
        let keyPrefix = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString
        let turnID = rolloutTurnID(object: object, payload: payload) ?? currentTurnID

        if let telemetry = ThroughputSignal.parse(object: object, payload: payload, at: timestamp, turn: turnID) {
            var event = RolloutMetricEvent(timestamp: timestamp,
                key: "telemetry:\(telemetry.kind):\(telemetry.itemID):\(timestamp)", turnID: turnID, category: nil, text: "")
            event.telemetry = telemetry
            return [event]
        }

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
        let tailData = try handle.readShared(upToCount: Int(tailByteCount))
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
        var currentTurnID: String? = nil
        var initialCacheContextReset = false
        var initialCacheContextEstablished = false
        if parseStart < completeEnd,
           let text = String(data: Data(bytes[parseStart..<completeEnd]), encoding: .utf8) {
            var foundCacheBoundary = !CacheMissReminderFeature.isEnabled
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any] else { continue }
                if currentTurnID == nil,
                   object["type"] as? String == "turn_context" || payload["type"] as? String == "turn_context" {
                    currentTurnID = rolloutTurnID(object: object, payload: payload)
                }
                if !foundCacheBoundary,
                   let sample = CacheUsageSample.parse(object: object, payload: payload,
                       timestamp: .nan) {
                    if sample.reset {
                        initialCacheContextReset = true
                        foundCacheBoundary = true
                    } else if let input = sample.input, let cached = sample.cached, input > 0, cached <= input,
                              let timestamp = parseTimestamp(object["timestamp"] as? String),
                              timestamp.isFinite, timestamp >= 0 {
                        initialCacheContextEstablished = true
                        foundCacheBoundary = true
                    }
                }
                if currentTurnID != nil && foundCacheBoundary { break }
            }
        }
        var state = try rolloutReadState(
            handle: handle,
            offset: tailOffset + UInt64(completeEnd),
            currentTurnID: currentTurnID,
            fileIdentity: metadata.identity,
            discardLeadingPartialLine: false
        )
        state.initialCacheContextReset = initialCacheContextReset
        state.initialCacheContextEstablished = initialCacheContextEstablished
        return state
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
        let data = try handle.readShared(upToCount: Int(requestedByteCount), probe: true)
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
        return LocalLogISO8601.date(from: text)?.timeIntervalSince1970
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
        consistency: SQLiteConnectionConsistency = .ordinary,
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        try SQLiteReadRecovery.run {
            let driver = SQLiteDatabaseDriver(
                url: URL(fileURLWithPath: path, isDirectory: false),
                readOnly: true,
                createsFileIfMissing: false,
                busyTimeoutMilliseconds: 3_000,
                enableWAL: false,
                consistency: consistency
            )
            return try driver.readRows(sql, bindings: bindings, map: map)
        }
    }

    nonisolated static func sqliteText(_ statement: SQLiteStatement, _ column: Int32) -> String? {
        statement.text(column)
    }

    nonisolated static func sqliteInt(_ statement: SQLiteStatement, _ column: Int32) -> Int {
        statement.int(column) ?? 0
    }
}
