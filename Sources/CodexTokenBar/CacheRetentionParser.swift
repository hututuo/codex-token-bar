import CoreFoundation
import Foundation

struct CacheRetentionUsage: Codable, Equatable, Sendable {
    var ordinal: Int64
    var timestamp: Int64?
    var input: Int64?
    var cached: Int64?
    var valid: Bool { guard let input, let cached else { return false }; return input > 0 && cached >= 0 && cached <= input }
}

struct CacheRetentionTurn: Codable, Equatable, Sendable {
    var id: String
    var stableID: Bool
    var ordinal: Int64
    var rootOrdinal: UInt64?
    var started: Int64?
    var ended: Int64?
    var marker: Int64?
    var first: CacheRetentionUsage?
    var last: CacheRetentionUsage?
    var models: Set<String> = []
    var reasons: Set<String> = []
    var inheritedSeedReasons: Set<String> = []
}

/// Persisted compact facts/checkpoint: no prompt, reply, or credentials.
struct CacheRetentionParser: Codable, Sendable {
    static let revision = "cache-retention-v7-native-density-1"
    var sessionKey = ""
    var excludedSubagent = false
    var explicitSubagent = false
    var metadataSeen = false
    var sourceFlags: Set<String> = []
    var turns: [CacheRetentionTurn] = []
    var current: Int?
    var pendingReasons: Set<String> = []
    var orphanMarker: Int64?
    var cumulativeTotal: Int64?
    var mirror: CacheRetentionUsage?
    var nextOrdinal: Int64 = 0
    var boundary: Boundary?
    var ownership = UsageAccountingState.fresh
    var legacyFork = false
    var replay = false
    var replayReference: Int64?
    var legacyOwnStart: Int64?

    struct Boundary: Codable, Sendable {
        var ordinal: UInt64
        var childCreated: UInt64?
        var mainFork: Bool
        var value: PaginatedHistoryBoundary.Metadata { .init(ordinal: ordinal, childCreatedMilliseconds: childCreated, isMainFork: mainFork) }
    }

    init(metadata: PaginatedHistoryBoundary.Metadata?) {
        boundary = metadata.map { Boundary(ordinal: $0.ordinal, childCreated: $0.childCreatedMilliseconds, mainFork: $0.isMainFork) }
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: n.objCType)) else { return nil }
        return Int64(n.stringValue)
    }

    static func time(_ value: Any?) -> Int64? {
        if let text = value as? String {
            let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text))
            guard let date else { return nil }
            let v = date.timeIntervalSince1970 * 1_000_000
            guard v.isFinite, v > Double(Int64.min), v < Double(Int64.max) else { return nil }
            return Int64(v.rounded())
        }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue * 1_000_000
        guard v.isFinite, v > Double(Int64.min), v < Double(Int64.max) else { return nil }
        return Int64(v.rounded())
    }

    static func isSubagent(_ p: [String: Any]) -> Bool {
        p["thread_source"] as? String == "subagent"
            || (p["source"] as? [String: Any])?["subagent"] != nil
            || !(p["agent_role"] as? String ?? "").isEmpty
            || !(p["agent_path"] as? String ?? "").isEmpty
    }

    mutating func consume(_ data: Data, knownSubagents: Set<String>) {
        let ordinal = nextOrdinal; nextOrdinal += 1
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            if let i = current, turns[i].ended == nil { turns[i].reasons.insert("evidence_incomplete") }
            else { pendingReasons.insert("evidence_incomplete") }
            return
        }
        if object["payload"] as? [String: Any] == nil,
           ["event_msg", "turn_context", "token_usage_record", "session_meta"].contains(type) {
            if let i = current, turns[i].ended == nil { turns[i].reasons.insert("missing_payload") }
            else { pendingReasons.insert("missing_payload") }
        }
        let p = object["payload"] as? [String: Any] ?? [:]
        let kind = p["type"] as? String
        let timestamp = Self.time(object["timestamp"])
        let oldBoundary = ownership.paginatedOwnStartOrdinal
        if boundary != nil, oldBoundary == nil,
           type == "turn_context" || (type == "event_msg" && kind == "task_started"),
           let line = String(data: data, encoding: .utf8) {
            PaginatedHistoryBoundary.observeOwnTurn(line, metadata: boundary?.value, state: &ownership)
        }
        if oldBoundary == nil, let own = ownership.paginatedOwnStartOrdinal {
            replay = false; cumulativeTotal = nil
            if let i = current, turns[i].rootOrdinal == own {
                turns[i].reasons.subtract(turns[i].inheritedSeedReasons)
                if let marker = turns[i].marker, marker < turns[i].ordinal { turns[i].marker = nil }
            }
            pendingReasons.removeAll()
        }
        if type == "session_meta" {
            if metadataSeen { sourceFlags.insert("multiple_session_metadata") }
            metadataSeen = true
            let id = p["id"] as? String ?? p["session_id"] as? String ?? ""
            sessionKey = CacheRetentionIdentity.hash(id)
            if id.isEmpty { sourceFlags.insert("missing_session_identity") }
            explicitSubagent = Self.isSubagent(p)
            excludedSubagent = explicitSubagent || knownSubagents.contains(id)
            legacyFork = !(p["forked_from_id"] as? String ?? "").isEmpty
            if legacyFork { replay = true; replayReference = timestamp ?? Self.time(p["timestamp"]) }
            return
        }
        if type == "event_msg", kind == "task_started" {
            if let i = current, turns[i].ended == nil {
                turns[i].reasons.insert("overlap_or_incomplete"); pendingReasons.insert("overlap_or_incomplete")
            }
            let id = p["turn_id"] as? String ?? ""
            var turn = CacheRetentionTurn(id: CacheRetentionIdentity.hash(id), stableID: UUID(uuidString: id) != nil,
                ordinal: ordinal, rootOrdinal: (object["ordinal"] as? NSNumber).flatMap { UInt64($0.stringValue) },
                started: Self.time(p["started_at"] ?? object["timestamp"]), marker: orphanMarker,
                reasons: pendingReasons, inheritedSeedReasons: pendingReasons)
            if id.isEmpty || turn.started == nil { turn.reasons.insert("missing_boundary") }
            turns.append(turn); current = turns.count - 1; pendingReasons.removeAll(); orphanMarker = nil; mirror = nil
            return
        }
        let user = (type == "response_item" && kind == "message" && p["role"] as? String == "user")
            || (type == "event_msg" && kind == "user_message")
        if user, replay, let timestamp, let reference = replayReference, timestamp - reference > 2_000_000 {
            replay = false
            if boundary == nil { legacyOwnStart = current.map { turns[$0].ordinal } ?? ordinal; cumulativeTotal = nil }
        }
        let compacted = type == "compacted" || (type == "event_msg" && ["context_compacted", "compaction"].contains(kind ?? ""))
        if compacted {
            if let i = current, turns[i].ended == nil { turns[i].reasons.insert("compaction") }
            else { pendingReasons.insert("compaction") }
            mirror = nil; return
        }
        guard let i = current, turns[i].ended == nil else {
            if user { orphanMarker = ordinal }
            if type == "event_msg", kind == "token_count" { pendingReasons.insert("usage_outside_turn"); mirror = nil }
            if type == "event_msg", kind == "task_complete", current == nil { pendingReasons.insert("orphan_complete") }
            else if type == "event_msg", kind == "task_complete" { pendingReasons.insert("completion_identity_mismatch") }
            if type == "token_usage_record" { pendingReasons.insert("usage_outside_turn") }
            if type == "event_msg", ["turn_aborted", "task_aborted"].contains(kind ?? "") { pendingReasons.insert("aborted") }
            return
        }
        if user {
            if turns[i].first != nil { turns[i].reasons.insert("inserted_or_reassigned_user_marker") }
            turns[i].marker = ordinal; return
        }
        if type == "turn_context" {
            if let id = p["turn_id"] as? String, CacheRetentionIdentity.hash(id) != turns[i].id { turns[i].reasons.insert("context_turn_mismatch") }
            if let model = p["model"] as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty { turns[i].models.insert(model.trimmingCharacters(in: .whitespaces)) }
            return
        }
        if type == "event_msg", ["turn_aborted", "task_aborted"].contains(kind ?? "") { turns[i].reasons.insert("aborted"); return }
        if type == "token_usage_record" {
            if CacheRetentionIdentity.hash(p["turn_id"] as? String ?? "") != turns[i].id { turns[i].reasons.insert("usage_turn_mismatch") }
            if mirror != nil { turns[i].reasons.insert("unmatched_usage_mirror") }
            let u = p["usage"] as? [String: Any] ?? [:]
            mirror = .init(ordinal: ordinal, timestamp: timestamp, input: Self.integer(u["input_tokens"]), cached: Self.integer(u["cached_input_tokens"]))
            return
        }
        if type == "event_msg", kind == "token_count" {
            let info = p["info"] as? [String: Any] ?? [:]
            let u = info["last_token_usage"] as? [String: Any] ?? [:]
            let usage = CacheRetentionUsage(ordinal: ordinal, timestamp: timestamp, input: Self.integer(u["input_tokens"]), cached: Self.integer(u["cached_input_tokens"]))
            if turns[i].marker == nil { turns[i].reasons.insert("missing_user_marker") }
            if let mirror, !mirror.valid || mirror.input != usage.input || mirror.cached != usage.cached { turns[i].reasons.insert("usage_mirror_mismatch") }
            mirror = nil
            if turns[i].first == nil { turns[i].first = usage }
            turns[i].last = usage
            let total = Self.integer((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if let total, total >= 0 {
                if let previous = cumulativeTotal, total < previous { turns[i].reasons.insert("cumulative_rollback") }
                cumulativeTotal = total
            }
            if replay { replayReference = timestamp ?? replayReference }
            return
        }
        if type == "event_msg", kind == "task_complete" {
            guard CacheRetentionIdentity.hash(p["turn_id"] as? String ?? "") == turns[i].id else { turns[i].reasons.insert("completion_identity_mismatch"); return }
            if mirror != nil { turns[i].reasons.insert("unmatched_usage_mirror"); mirror = nil }
            turns[i].ended = Self.time(p["completed_at"] ?? object["timestamp"])
            if turns[i].ended == nil || turns[i].started == nil || turns[i].ended! < turns[i].started! { turns[i].reasons.insert("invalid_boundary_time") }
        }
    }

    func isOwn(_ turn: CacheRetentionTurn) -> Bool {
        if let boundary {
            let limit = min(boundary.ordinal, ownership.paginatedOwnStartOrdinal ?? boundary.ordinal)
            guard limit != UInt64.max, let ordinal = turn.rootOrdinal else { return false }
            return ordinal >= limit
        }
        if legacyFork { return legacyOwnStart.map { turn.ordinal >= $0 } ?? false }
        return true
    }

    func pairs(source: String, generation: String) -> [CacheRetentionPair] {
        guard !excludedSubagent else { return [] }
        var flags = sourceFlags
        if !metadataSeen { flags.insert("missing_source_metadata") }
        let ownIDs = turns.filter(isOwn).map(\.id)
        if Set(ownIDs).count != ownIDs.count { flags.insert("repeated_turn_identity") }
        func reasons(_ t: CacheRetentionTurn) -> Set<String> {
            var r = t.reasons
            if !isOwn(t) { r.insert("inherited") }
            if t.ended == nil { r.insert("pending") }
            if t.models.count != 1 { r.insert("missing_or_changed_model") }
            if t.first == nil { r.insert("usage_unseen") }
            else if t.first?.valid != true { r.insert("first_usage_invalid") }
            if t.last?.valid != true { r.insert("last_usage_invalid") }
            for u in [t.first, t.last].compactMap({ $0 }) {
                guard let time = u.timestamp, let start = t.started else { r.insert("usage_outside_boundary_time"); continue }
                if time < start || (t.ended.map { time > $0 && time - $0 > 999_999 } ?? false) { r.insert("usage_outside_boundary_time") }
            }
            return r
        }
        return zip(turns, turns.dropFirst()).map { previous, next in
            var r = flags.union(reasons(previous)).union(reasons(next))
            if previous.models != next.models { r.insert("cross_model") }
            let delta = next.started.flatMap { start in previous.ended.flatMap { end -> Int64? in
                let value = start.subtractingReportingOverflow(end); return value.overflow ? nil : value.partialValue
            }}
            if delta == nil || delta! < 0 { r.insert("negative_or_missing_gap") }
            if let u = previous.last, u.valid, let input = u.input, let cached = u.cached, cached < input - input / 5 { r.insert("previous_not_high") }
            let id = CacheRetentionIdentity.hash("\(source):\(generation):\(previous.ordinal):\(next.ordinal):\(previous.id):\(next.id)")
            var point: CacheRetentionPoint?
            if let gap = delta, gap >= 0, let start = next.started, let model = next.models.first,
               let a = previous.last, a.valid, let b = next.first, b.valid {
                point = .init(id: id, sourceKey: source, sessionKey: sessionKey, model: model, gapMicroseconds: gap,
                    startedAtMicroseconds: start, previousInput: a.input!, previousCached: a.cached!, input: b.input!, cached: b.cached!)
            }
            let values: [String] = [delta.map(String.init) ?? "missing", next.started.map(String.init) ?? "missing",
                next.models.count == 1 ? next.models.first! : "missing",
                previous.last?.input.map(String.init) ?? "missing", previous.last?.cached.map(String.init) ?? "missing",
                next.first?.input.map(String.init) ?? "missing", next.first?.cached.map(String.init) ?? "missing"]
            return .init(id: id, sessionKey: sessionKey, previousID: previous.id, nextID: next.id,
                stableTurnIDs: previous.stableID && next.stableID, evidenceSignature: CacheRetentionIdentity.hash(values.joined(separator: ":")), point: point, reasons: r)
        }
    }
}
