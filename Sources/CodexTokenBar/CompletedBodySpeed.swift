import Foundation
import CryptoKit
import CoreFoundation
import TiktokenSwift

/// Fully local, bundled tokenizer. Never downloads a vocabulary or sends response text.
enum BodySpeedTokenizer {
    static func load() throws -> CoreBpe {
        guard let url = AppResources.url(forResource: "o200k_base", withExtension: "tiktoken") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
              let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var ranks: [[UInt8]: UInt32] = [:]
        ranks.reserveCapacity(199_998)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])),
                  let rank = UInt32(parts[1]) else { throw CocoaError(.fileReadCorruptFile) }
            ranks[Array(bytes)] = rank
        }
        let pattern = #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        return try newCoreBpe(encoder: ranks, specialTokensEncoder: ["<|endoftext|>": 199999, "<|endofprompt|>": 200018], pattern: pattern)
    }
}

/// Joins two explicit facts, not inferred request boundaries. Text lives only in this bounded buffer.
struct CompletedBodyAssembler: Sendable {
    private static let markers = ["\"session_meta\"", "\"turn_context\"", "\"task_started\"", "\"AgentMessage\"", "\"output_text\""].map { Data($0.utf8) }
    struct Part: Sendable {
        var turn: String
        var item: String
        var text: String?
        var start: Double?
        var end: Double?
        var at: Double
        var phase: String? = nil
        var ownedByOrdinal = false
        var bornOwn = false
    }
    var currentTurn = ""
    var models: [String: String] = [:]
    var pending: [String: Part] = [:]
    var createdAt: Double?
    var inheritedBoundary: UInt64?
    var childCreatedMS: UInt64?
    var ownership = UsageAccountingState.fresh
    var hasFork = false

    mutating func configure(metadata: [String: Any]) {
        hasFork = !(metadata["forked_from_id"] as? String ?? "").isEmpty || Self.isSubagentMetadata(metadata)
        if hasFork {
            childCreatedMS = PaginatedHistoryBoundary.uuidMilliseconds(metadata["id"] as? String)
            createdAt = childCreatedMS.map { Double($0) / 1000 }
                ?? (metadata["timestamp"] as? String).flatMap(Self.time)
        }
        if metadata["history_mode"] as? String == "paginated" {
            inheritedBoundary = PaginatedHistoryBoundary.unsigned(metadata["subagent_history_start_ordinal"])
            if hasFork && inheritedBoundary == nil { inheritedBoundary = UInt64.max }
        }
    }
    static func isSubagentMetadata(_ metadata: [String: Any]) -> Bool {
        metadata["thread_source"] as? String == "subagent"
            || (metadata["source"] as? [String: Any])?["subagent"] != nil
            || !(metadata["agent_role"] as? String ?? "").isEmpty
            || !(metadata["agent_path"] as? String ?? "").isEmpty
    }
    static func time(_ text: String) -> Double? {
        ((try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text)))?.timeIntervalSince1970
    }
    static func milliseconds(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    mutating func consume(_ line: Data, thread: String, now: Double, tokenizer: (String) throws -> Int) rethrows -> ObservedSpeedSample? {
        guard line.count <= 1_100_000,
              Self.markers.contains(where: { line.range(of: $0) != nil }),
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let p = root["payload"] as? [String: Any], let type = root["type"] as? String else { return nil }
        if type == "session_meta" { configure(metadata: p); return nil }
        let at = (root["timestamp"] as? String).flatMap(Self.time) ?? 0
        let explicitTurn = p["turn_id"] as? String ?? root["turn_id"] as? String
            ?? (p["metadata"] as? [String: Any])?["turn_id"] as? String
        if type == "turn_context" || (type == "event_msg" && p["type"] as? String == "task_started") {
            if let turn = explicitTurn, !turn.isEmpty { currentTurn = turn }
            if let model = p["model"] as? String, !model.isEmpty, !currentTurn.isEmpty { models[currentTurn] = model }
            if models.count > 128 { models = models.filter { entry in entry.key == currentTurn || pending.values.contains(where: { $0.turn == entry.key }) } }
            if let boundary = inheritedBoundary, let text = String(data: line, encoding: .utf8) {
                PaginatedHistoryBoundary.observeOwnTurn(text, metadata: .init(ordinal: boundary, childCreatedMilliseconds: childCreatedMS), state: &ownership)
            }
            return nil
        }
        let turn = explicitTurn ?? currentTurn
        guard !turn.isEmpty else { return nil }
        var part: Part
        if type == "event_msg", p["type"] as? String == "item_completed",
           let item = p["item"] as? [String: Any], (item["type"] as? String)?.lowercased() == "agentmessage",
           let id = item["id"] as? String, !id.isEmpty,
           let start = Self.milliseconds(p["started_at_ms"]) ?? Self.milliseconds(item["started_at_ms"]),
           let end = Self.milliseconds(p["completed_at_ms"]) ?? Self.milliseconds(item["completed_at_ms"]),
           start.isFinite, end.isFinite, start > 0, end > start {
            part = Part(turn: turn, item: id, start: start / 1000, end: end / 1000, at: at, phase: item["phase"] as? String)
        } else if type == "response_item", p["type"] as? String == "message", p["role"] as? String == "assistant",
                  let id = p["id"] as? String, !id.isEmpty,
                  let content = p["content"] as? [[String: Any]] {
            let text = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty, text.utf8.count <= 1_048_576 else { return nil }
            part = Part(turn: turn, item: id, text: text, at: at, phase: p["phase"] as? String)
        } else { return nil }
        let ordinalOwn = inheritedBoundary.map { boundary in
            let own = ownership.paginatedOwnStartOrdinal ?? boundary
            return PaginatedHistoryBoundary.unsigned(root["ordinal"]).map { $0 >= own } == true
        } ?? false
        let bornOwn = childCreatedMS.flatMap { created in
            PaginatedHistoryBoundary.uuidMilliseconds(turn).map { $0 >= created }
        } == true
        if inheritedBoundary != nil {
            guard ordinalOwn || bornOwn else { return nil }
        } else if hasFork {
            let timestampOwn = createdAt.map { at >= $0 } == true
            guard timestampOwn || bornOwn else { return nil }
        }
        part.ownedByOrdinal = ordinalOwn
        part.bornOwn = bornOwn
        let key = "\(turn)/\(part.item)"
        if let old = pending[key] {
            part.text = part.text ?? old.text
            part.start = part.start ?? old.start
            part.end = part.end ?? old.end
            part.phase = part.phase ?? old.phase
            part.ownedByOrdinal = part.ownedByOrdinal || old.ownedByOrdinal
            part.bornOwn = part.bornOwn || old.bornOwn
        }
        // Bound by timestamps as well as entry/byte counts; no reply content is persisted.
        pending = pending.filter { $0.value.at >= max(now - 3600, at - 600) }
        if let text = part.text, let start = part.start, let end = part.end {
            pending.removeValue(forKey: key)
            guard end >= now - 30 * 86400, end <= now + 2, end > start,
                  !hasFork || createdAt.map({ start >= $0 }) != false || part.ownedByOrdinal || part.bornOwn else { return nil }
            let tokens = try tokenizer(text), duration = end - start
            guard tokens > 0 else { return nil }
            var sample = ObservedSpeedSample(id: "body/\(thread)/\(key)", threadID: thread, turnID: turn, itemID: part.item,
                model: models[turn] ?? "unknown", startedAt: start, endedAt: end, outputTokens: tokens,
                outputCharacters: text.count, outputBytes: text.utf8.count, chunkCount: 0, durationSeconds: duration,
                tokensPerSecond: Double(tokens) / duration, confidence: "low",
                networkWarning: nil, source: "本地正文起止计时 / 离线 o200k_base 分词（非网络包测速）",
                measurementKind: "completed_body", tokenizer: "o200k_base", bodyPhase: part.phase)
            let quality = sample.bodyQuality
            sample.confidence = quality.confidence
            sample.qualityReason = quality.reason
            return sample
        }
        pending[key] = part
        while pending.count > 32 || pending.values.reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) > 4 * 1_048_576 {
            guard let oldest = pending.min(by: { $0.value.at < $1.value.at })?.key else { break }
            pending.removeValue(forKey: oldest)
        }
        return nil
    }
}

/// Utility-actor reader: one bounded recent-history backfill, then complete appended lines only.
/// It has its own cursor so backfill never replays old usage into the live curve or accounting index.
actor CompletedBodySpeedReader {
    struct State {
        var offset: UInt64 = 0
        var identity: String = ""
        var assembler = CompletedBodyAssembler()
        var discardPartial = false
        var boundary: Data?
    }
    struct Result: Sendable {
        /// Complete retained snapshot for existing reader callers.
        var samples: [String: [ObservedSpeedSample]] = [:]
        /// New or not-yet-accepted samples, keyed by rollout path.
        var pendingSamplesByPath: [String: [ObservedSpeedSample]] = [:]
        /// Highest revision represented by each pending sample batch.
        var revisionsByPath: [String: UInt64] = [:]
        var error: String?
    }
    private struct PendingSample: Sendable {
        let revision: UInt64
        let sample: ObservedSpeedSample
    }
    private var states: [String: State] = [:]
    private var encoder: CoreBpe?
    private var recent: [String: [ObservedSpeedSample]] = [:]
    private var sampleRevisionsByPath: [String: UInt64] = [:]
    private var pendingSamplesByPath: [String: [PendingSample]] = [:]
    private var lastPrunedAt: Double?
    private func boundary(_ handle: FileHandle, at offset: UInt64) throws -> Data {
        let count = min(offset, 128)
        try handle.seek(toOffset: offset - count)
        return try handle.readShared(upToCount: Int(count), probe: true)
    }
    func read(
        options: [LiveThreadOption],
        now: Double,
        acceptedRevisions: [String: UInt64] = [:]
    ) -> Result {
        var result = Result()
        // Acknowledge only revisions the main actor committed after source validation.
        // If rollout parsing or poll application failed, the caller keeps its older
        // revision and these samples are returned again on the next read.
        for (path, acceptedRevision) in acceptedRevisions {
            guard let pending = pendingSamplesByPath[path] else { continue }
            let remaining = pending.filter { $0.revision > acceptedRevision }
            if remaining.isEmpty { pendingSamplesByPath.removeValue(forKey: path) }
            else { pendingSamplesByPath[path] = remaining }
        }
        do {
            if encoder == nil { encoder = try BodySpeedTokenizer.load() }
            guard let encoder else { return result }
            var budget = 64 * 1_048_576
            var seen: Set<String> = []
            var recentIDsByPath: [String: Set<String>] = [:]
            for option in options.sorted(by: { $0.updatedAtMS > $1.updatedAtMS }).prefix(64) where budget > 0 {
                guard let path = option.normalizedRolloutPath, seen.insert(path).inserted,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
                defer { try? handle.close() }
                if states[path] == nil, let modified = attrs[.modificationDate] as? Date,
                   modified.timeIntervalSince1970 < now - 30 * 86400 { continue }
                let identity = "\(attrs[.systemNumber] ?? "")/\(attrs[.systemFileNumber] ?? "")"
                var state = states[path] ?? State()
                let changedBoundary = size >= state.offset && state.boundary != nil
                    ? try boundary(handle, at: state.offset) != state.boundary : false
                if state.identity != identity || size < state.offset || changedBoundary {
                    state = State(); state.identity = identity
                    // Read only the header for ownership; do not scan inherited history.
                    let head = try handle.readShared(upToCount: 64 * 1024, probe: true)
                    if let newline = head.firstIndex(of: 10),
                       let root = try? JSONSerialization.jsonObject(with: head[..<newline]) as? [String: Any],
                       let payload = root["payload"] as? [String: Any] { state.assembler.configure(metadata: payload) }
                    state.offset = size > 8 * 1_048_576 ? size - 8 * 1_048_576 : 0
                    state.discardPartial = state.offset > 0
                }
                guard size > state.offset else { states[path] = state; continue }
                try handle.seek(toOffset: state.offset)
                let amount = min(budget, 8 * 1_048_576, Int(size - state.offset))
                let data = try handle.readShared(upToCount: amount)
                budget -= data.count
                guard let last = data.lastIndex(of: 10) else {
                    // A corrupt giant line is skipped within the fixed budget, not retained forever.
                    if data.count >= 1_100_000 { state.offset += UInt64(data.count); state.discardPartial = true; state.boundary = try boundary(handle, at: state.offset) }
                    states[path] = state; continue
                }
                var start = data.startIndex
                if state.discardPartial, let first = data.firstIndex(of: 10) { start = data.index(after: first); state.discardPartial = false }
                if start <= last {
                    for line in data[start...last].split(separator: 10) {
                        if let sample = state.assembler.consume(Data(line), thread: option.id, now: now, tokenizer: { encoder.encodeOrdinary(text: $0).count }) {
                            if recentIDsByPath[path] == nil {
                                recentIDsByPath[path] = Set(recent[path, default: []].map(\.id))
                            }
                            if recentIDsByPath[path, default: []].insert(sample.id).inserted {
                                recent[path, default: []].append(sample)
                                let revision = sampleRevisionsByPath[path, default: 0] &+ 1
                                sampleRevisionsByPath[path] = revision
                                pendingSamplesByPath[path, default: []].append(
                                    PendingSample(revision: revision, sample: sample)
                                )
                            }
                        }
                    }
                }
                state.offset += UInt64(data.distance(from: data.startIndex, to: data.index(after: last)))
                state.boundary = try boundary(handle, at: state.offset)
                states[path] = state
            }
            // Expiring and capping every retained sample list on every poll made an
            // idle reader repeatedly scan the full 30-day cache. Prune at most once
            // per minute; a backwards wall-clock adjustment must never trigger an
            // early expiration pass.
            if now.isFinite, lastPrunedAt.map({ now >= $0 && now - $0 >= 60 }) ?? true {
                let cutoff = now - 30 * 86400
                for path in Array(recent.keys) {
                    let retained = Array((recent[path] ?? []).filter { $0.endedAt >= cutoff }.suffix(2_000))
                    if retained.isEmpty { recent.removeValue(forKey: path) }
                    else { recent[path] = retained }
                    let retainedIDs = Set(retained.map(\.id))
                    let pending = (pendingSamplesByPath[path] ?? []).filter { retainedIDs.contains($0.sample.id) }
                    if pending.isEmpty { pendingSamplesByPath.removeValue(forKey: path) }
                    else { pendingSamplesByPath[path] = pending }
                }
                lastPrunedAt = now
            }
            result.samples = recent
            result.pendingSamplesByPath = pendingSamplesByPath.mapValues { $0.map(\.sample) }
            result.revisionsByPath = pendingSamplesByPath.compactMapValues { $0.last?.revision }
            if states.count > 128 { states = states.filter { seen.contains($0.key) } }
        } catch { result.error = "正文测速暂不可用：\(error.localizedDescription)" }
        return result
    }
}
