import Foundation
import CoreFoundation

/// Re-read the declared boundary on append resumes without changing the DB
/// schema. Optional ownership proof lives in the existing accounting JSON;
/// old v0.9.1 / v4 checkpoints remain decodable. Preserve descriptor position.
enum PaginatedHistoryBoundary {
    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = UInt64(number.stringValue) else { return nil }
        return result
    }

    struct Metadata {
        let ordinal: UInt64
        let childCreatedMilliseconds: UInt64?
        var isMainFork: Bool = false
    }

    static func uuidMilliseconds(_ value: String?) -> UInt64? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex[hex.index(hex.startIndex, offsetBy: 12)] == "7" else { return nil }
        return UInt64(hex.prefix(12), radix: 16)
    }

    static func read(file: URL, handle: FileHandle? = nil) throws -> UInt64? {
        try metadata(file: file, handle: handle)?.ordinal
    }

    static func metadata(file: URL, handle supplied: FileHandle? = nil) throws -> Metadata? {
        let handle = try supplied ?? FileHandle(forReadingFrom: file)
        let position = try handle.offset()
        defer {
            try? handle.seek(toOffset: position)
            if supplied == nil { try? handle.close() }
        }
        try handle.seek(toOffset: 0)
        var data = Data()
        while data.count < 8 * 1024 * 1024 {
            let chunk = try handle.read(upToCount: min(64 * 1024, 8 * 1024 * 1024 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: 10) {
                data.append(contentsOf: chunk[..<newline])
                break
            }
            data.append(chunk)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any],
              payload["history_mode"] as? String == "paginated" else { return nil }
        let value = payload["subagent_history_start_ordinal"]
        let hasBoundary = value != nil && !(value is NSNull)
        let fork = (payload["forked_from_id"] as? String)?.isEmpty == false
        guard hasBoundary || fork else { return nil }
        guard let boundary = hasBoundary ? unsigned(value) : UInt64.max else { throw CocoaError(.fileReadCorruptFile) }
        let explicit = payload["thread_source"] as? String == "subagent"
            || (payload["source"] as? [String: Any])?["subagent"] != nil
        return Metadata(ordinal: boundary, childCreatedMilliseconds: explicit || fork
            ? uuidMilliseconds(payload["id"] as? String) : nil, isMainFork: !hasBoundary)
    }
    /// Migration may stamp an entire old rollout as inherited, including the
    /// child's own completed turns. A matching UUIDv7 task/context pair born
    /// after the child is independent evidence; rewritten envelope timestamps
    /// alone are not. Keep this proof in the existing incremental checkpoint.
    static func observeOwnTurn(_ line: String, metadata: Metadata?, state: inout UsageAccountingState) {
        guard let metadata, let created = metadata.childCreatedMilliseconds,
              state.paginatedOwnStartOrdinal == nil,
              line.contains("\"task_started\"") || line.contains("\"turn_context\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ordinal = unsigned(root["ordinal"]), ordinal < metadata.ordinal,
              let payload = root["payload"] as? [String: Any] else { return }
        func synthetic(_ value: String) -> Bool {
            value.hasPrefix("rollout-") && UInt64(value.dropFirst(8)) != nil
        }
        if root["type"] as? String == "event_msg", payload["type"] as? String == "task_started" {
            let turn = payload["turn_id"] as? String
            if state.paginatedPendingIsContext == true,
               let context = state.paginatedPendingTurnID,
               let contextOrdinal = state.paginatedPendingTurnOrdinal, contextOrdinal < ordinal,
               let turn, turn == context || synthetic(turn) {
                // A restored context may be followed by an inherited cumulative
                // seed. Do not count that seed before the synthetic task starts.
                state.paginatedOwnStartOrdinal = ordinal
                state.paginatedPendingTurnID = nil
                state.paginatedPendingTurnOrdinal = nil
                state.paginatedPendingIsContext = nil
                return
            }
            state.paginatedPendingTurnID = nil
            state.paginatedPendingTurnOrdinal = nil
            state.paginatedPendingIsContext = nil
            if let turn, (uuidMilliseconds(turn).map { $0 >= created } == true || synthetic(turn)) {
                state.paginatedPendingTurnID = turn
                state.paginatedPendingTurnOrdinal = ordinal
            }
        } else if root["type"] as? String == "turn_context",
                  let turn = payload["turn_id"] as? String,
                  uuidMilliseconds(turn).map({ $0 >= created }) == true {
            if state.paginatedPendingIsContext != true,
               let pending = state.paginatedPendingTurnID,
               turn == pending || synthetic(pending),
               let started = state.paginatedPendingTurnOrdinal, started < ordinal {
                state.paginatedOwnStartOrdinal = started
                state.paginatedPendingTurnID = nil
                state.paginatedPendingTurnOrdinal = nil
                state.paginatedPendingIsContext = nil
            } else if state.paginatedPendingTurnID == nil {
                state.paginatedPendingTurnID = turn
                state.paginatedPendingTurnOrdinal = ordinal
                state.paginatedPendingIsContext = true
            }
        }
    }
}
