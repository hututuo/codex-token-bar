import Foundation
import CryptoKit

/// Animation allocation only. Never writes to the usage ledger or serves as a measured sample.
struct ThroughputSignal {
    var kind: String
    var timestamp: Double
    var turnID: String
    var model: String = ""
    var itemID: String = ""
    var duration: Double = 0
    var output: Double = 0
    var reasoning: Double = 0
}

struct ThroughputCurve {
    struct Session {
        var turn = ""
        var model = "unknown"
        var budget = 0.0
        var moment = 0.0
        var debt = 0.0
        var rate = 0.0
        var queue = Array(repeating: 0.0, count: 5)
        var lastTick = 0.0
        var lastQuantity = 0.0
        var lastSettlement = 0.0
        var provisional = 0.0
        var reasoningDuration = 0.0
        var finish: Double?
        var stopped = false
        var paused = false
        var seen = Set<String>()
        var history: [String: [Double]] = [:]
        var display = 0.0
    }
    var sessions: [String: Session] = [:]

    mutating func consume(_ signal: ThroughputSignal, thread: String, now: Double) {
        // Startup/backfill and delayed old packets may update accounting elsewhere, but never animate.
        guard signal.timestamp >= now - 20, signal.timestamp <= now + 2 else { return }
        var s = sessions[thread] ?? Session()
        if !signal.turnID.isEmpty, signal.turnID != s.turn {
            guard signal.kind == "start" || signal.timestamp >= s.lastQuantity else { return }
            let history = s.history
            let model = s.model
            s = Session(); s.turn = signal.turnID; s.history = history; s.model = model
        }
        if !signal.model.isEmpty { s.model = signal.model }
        Self.advance(&s, to: signal.timestamp)
        let identity = "\(signal.kind):\(signal.itemID):\(signal.timestamp)"
        guard s.seen.insert(identity).inserted else { return }
        if s.seen.count > 4096 { s.seen = [identity] }
        switch signal.kind {
        case "context", "start": break
        case "abort", "failure", "pause":
            s.budget = 0; s.moment = 0; s.rate = 0; s.queue = Array(repeating: 0, count: 5)
            s.display = 0; s.stopped = signal.kind != "pause"; s.paused = signal.kind == "pause"
        case "complete": s.finish = signal.timestamp
        case "observed":
            guard !s.stopped, s.finish == nil else { break }
            s.paused = false; s.provisional += max(0, signal.output)
            Self.allocate(max(0, signal.output), horizon: 1, session: &s)
            s.lastQuantity = signal.timestamp
        case "reasoning":
            guard !s.stopped, s.finish == nil else { break }
            s.paused = false
            let rates = s.history[s.model] ?? []
            let sorted = rates.sorted()
            let baseline = sorted.isEmpty ? 40 : (sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2])
            let duration = max(0, min(signal.duration, 3600))
            let tokens = baseline * duration
            s.provisional += tokens; s.reasoningDuration += duration
            Self.allocate(tokens, horizon: max(1, duration), session: &s)
            s.lastQuantity = signal.timestamp
        case "usage":
            guard !s.stopped, !s.paused, s.finish.map({ signal.timestamp <= $0 + 1 }) ?? true else { break }
            Self.allocate(signal.output - s.provisional,
                          horizon: max(1, s.lastSettlement > 0 ? signal.timestamp - s.lastSettlement : s.reasoningDuration), session: &s)
            if s.reasoningDuration >= 1, signal.reasoning > 0 {
                var history = s.history[s.model] ?? []
                history.append(signal.reasoning / s.reasoningDuration)
                s.history[s.model] = Array(history.suffix(5))
            }
            s.provisional = 0; s.reasoningDuration = 0
            s.lastSettlement = signal.timestamp; s.lastQuantity = signal.timestamp
        default: break
        }
        if s.lastTick == 0 { s.lastTick = floor(signal.timestamp) }
        sessions[thread] = s
    }

    private static func allocate(_ amount: Double, horizon: Double, session s: inout Session) {
        guard amount.isFinite, horizon.isFinite else { return }
        if amount < 0 {
            let removed = min(s.budget, -amount)
            if s.budget > 0 { s.moment *= 1 - removed / s.budget }
            s.budget -= removed; s.debt += -amount - removed
        } else {
            let repaid = min(s.debt, amount); s.debt -= repaid
            let quantity = amount - repaid
            s.budget += quantity; s.moment += quantity * horizon
        }
    }

    private static func advance(_ s: inout Session, to now: Double) {
            if s.stopped || s.paused || now - s.lastQuantity >= 20 || s.finish.map({ now >= $0 + 5 }) == true {
                s.budget = 0; s.moment = 0; s.rate = 0; s.queue = Array(repeating: 0, count: 5); s.display = 0
                s.lastTick = floor(now); return
            }
            // One-second source samples match the approved preview; finite filter has a 2s mean lag.
            if s.lastTick == 0 { s.lastTick = floor(now); return }
            while s.lastTick + 1 <= now {
                s.lastTick += 1
                let horizon = s.budget > 0 ? max(1, s.moment / s.budget) : 1
                let target = s.budget / horizon
                s.rate += (target - s.rate) * (target >= s.rate ? 0.28 : 0.18)
                let quantity = min(s.budget, max(0, s.rate))
                if s.budget > 0 { s.moment *= 1 - quantity / s.budget }
                s.budget -= quantity
                let weights = [1.0, 2, 3, 2, 1]
                for i in 0..<5 { s.queue[i] += quantity * weights[i] / 9 }
                s.display = s.queue.removeFirst(); s.queue.append(0)
                if let finish = s.finish, s.lastTick > finish + 3 {
                    let x = min(1, max(0, (finish + 5 - s.lastTick) / 2))
                    s.display *= x * x * (3 - 2 * x)
                }
            }
    }

    mutating func tick(now: Double) {
        for thread in Array(sessions.keys) {
            guard var s = sessions[thread] else { continue }
            Self.advance(&s, to: now)
            sessions[thread] = s
        }
        // Bound idle thread metadata independently of preserved usage/history indexes.
        if sessions.count > 512 {
            let expired = sessions.filter { now - $0.value.lastQuantity > 3600 }.map(\.key)
            for key in expired { sessions.removeValue(forKey: key) }
        }
    }
    var modelRates: [ModelRateContribution] {
        var grouped: [String: Double] = [:]
        for session in sessions.values where session.display.isFinite && session.display > 0 {
            let model = session.model.trimmingCharacters(in: .whitespacesAndNewlines)
            grouped[model.isEmpty ? "unknown" : model, default: 0] += session.display
        }
        return grouped.keys.sorted().map { ModelRateContribution(model: $0, tokensPerSecond: grouped[$0]!) }
    }
    var total: Double { modelRates.reduce(0) { $0 + $1.tokensPerSecond } }
    func rate(thread: String) -> Double { sessions[thread]?.display ?? 0 }
    var active: Bool { sessions.values.contains { !$0.stopped && ($0.budget > 0 || $0.queue.contains { $0 > 0 }) } }
}

struct ObservedSpeedSample: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var threadID: String
    var turnID: String
    var itemID: String
    var model: String
    var startedAt: Double
    var endedAt: Double
    var outputTokens: Int
    var outputCharacters: Int
    var outputBytes: Int
    var chunkCount: Int
    var durationSeconds: Double
    var tokensPerSecond: Double
    var confidence: String
    var networkWarning: String?
    var source: String
    var measurementKind: String? = nil
    var tokenizer: String? = nil
    var bodyPhase: String? = nil
    var qualityReason: String? = nil

    var isBody: Bool { measurementKind == "completed_body" && tokenizer == "o200k_base" }
    var hasKnownModel: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown" }
    var bodyQuality: BodySpeedQuality { BodySpeedQuality.assess(self) }
    var bodyTypeLabel: String {
        switch bodyPhase { case "commentary": "中间消息"; case "final_answer": "最终文本"; default: "正文" }
    }
}

struct BodySpeedQuality: Equatable, Sendable {
    var confidence: String
    var reason: String?
    var included: Bool { confidence != "low" }
    var statusLabel: String {
        if included { return "计入均速" }
        switch reason {
        case "采样时长不超过 0.4 秒": return "时长≤0.4秒"
        case "速率异常偏高", "速率异常偏低": return "速率待核查"
        case "采样存在异常标记": return "采样告警"
        default: return "计时待核查"
        }
    }
    static func assess(_ sample: ObservedSpeedSample) -> Self {
        guard sample.outputTokens > 0, sample.durationSeconds.isFinite, sample.durationSeconds > 0,
              sample.tokensPerSecond.isFinite, sample.startedAt.isFinite, sample.endedAt.isFinite,
              sample.endedAt > sample.startedAt else { return .init(confidence: "low", reason: "计时无效") }
        let rate = Double(sample.outputTokens) / sample.durationSeconds
        if abs(sample.endedAt - sample.startedAt - sample.durationSeconds) > 0.01
            || abs(rate - sample.tokensPerSecond) > max(0.01, rate * 0.001) {
            return .init(confidence: "low", reason: "数量与计时不一致")
        }
        // Rollout timestamps have millisecond precision. Compare their original
        // resolution so a rounded Unix Double cannot admit an exact 400ms body.
        let elapsedMS = (sample.endedAt * 1000).rounded() - (sample.startedAt * 1000).rounded()
        if elapsedMS <= 400 { return .init(confidence: "low", reason: "采样时长不超过 0.4 秒") }
        if rate > 500 { return .init(confidence: "low", reason: "速率异常偏高") }
        if rate < 2 { return .init(confidence: "low", reason: "速率异常偏低") }
        if sample.networkWarning != nil { return .init(confidence: "low", reason: "采样存在异常标记") }
        return .init(confidence: sample.durationSeconds >= 5 ? "high" : "medium", reason: nil)
    }
}
struct ModelSpeedSummary: Equatable, Identifiable {
    var model: String
    var tokensPerSecond: Double
    var sampleCount: Int
    var outputTokens: Int
    var durationSeconds: Double
    var activeSampleCount = 0
    var qualifiedSampleCount = 0
    var confidence = "low"
    var lastMeasuredAt: Double? = nil
    var id: String { model }
}

struct BodySpeedModelReading: Identifiable {
    let summary: ModelSpeedSummary
    let historical: Bool
    var id: String { summary.model }

    static func combined(recent: [ModelSpeedSummary], retained: [ModelSpeedSummary]) -> [Self] {
        var readings: [String: Self] = [:]
        for (summaries, historical) in [(retained, true), (recent, false)] {
            for summary in summaries where !summary.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown"
                && summary.sampleCount > 0 && summary.tokensPerSecond.isFinite && summary.tokensPerSecond > 0 {
                readings[summary.model] = Self(summary: summary, historical: historical)
            }
        }
        return readings.values.sorted {
            if $0.historical != $1.historical { return !$0.historical }
            if $0.summary.lastMeasuredAt != $1.summary.lastMeasuredAt {
                return ($0.summary.lastMeasuredAt ?? 0) > ($1.summary.lastMeasuredAt ?? 0)
            }
            return $0.id < $1.id
        }
    }
}

/// Receipt timing is measured; local tokenizer output is an estimate, not billable usage.
struct ObservedSpeedCollector {
    struct Pending {
        var thread: String; var turn: String; var item: String; var model: String
        var first: Double; var last: Double
        var source = "Codex 本地流式增量 · 接收计时 / 本地分词估算"
        var firstText = ""; var text = ""; var chunks = 0; var maxGap = 0.0; var truncated = false; var sawStart = false
        var liveTokens = 0
    }
    var pending: [String: Pending] = [:]
    var startedItems: Set<String> = []
    var samples: [ObservedSpeedSample] = []
    var revision = 0
    var persistenceError: String?
    var storeURL: URL?
    private var canPersist = true
    var persistenceAllowed: Bool { canPersist }

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard size <= 64 * 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: storeURL)
                samples = try JSONDecoder().decode([ObservedSpeedSample].self, from: data)
            } catch {
                persistenceError = "既有测速记录无法读取，已保留原文件；暂停写入：\(error.localizedDescription)"
                canPersist = false
            }
        }
    }
    mutating func start(thread: String, item: String) {
        if startedItems.count > 512 { startedItems.removeAll() }
        startedItems.insert("\(thread)/\(item)")
    }
    mutating func append(thread: String, turn: String, item: String, model: String, text: String, at: Double, source: String? = nil, estimatedTokens: Int = 0) {
        guard !text.isEmpty, !thread.isEmpty, !turn.isEmpty, !item.isEmpty, item != "unknown" else { return }
        let key = "\(thread)/\(turn)/\(item)"
        var p = pending[key] ?? Pending(thread: thread, turn: turn, item: item, model: model, first: at, last: at)
        guard at >= p.last else { return }
        if !model.isEmpty, model != "unknown" { p.model = model }
        if let source { p.source = source }
        if p.chunks == 0 { p.firstText = text; p.sawStart = startedItems.contains("\(thread)/\(item)") }
        if p.chunks > 0 { p.liveTokens += max(0, estimatedTokens) }
        p.maxGap = max(p.maxGap, at - p.last); p.last = at; p.chunks += 1
        if p.text.utf8.count + text.utf8.count <= 1_048_576 { p.text += text } else { p.truncated = true }
        pending[key] = p
        if pending.count > 32 { pending.removeValue(forKey: pending.min { $0.value.last < $1.value.last }!.key) }
    }
    mutating func finish(thread: String? = nil, turn: String? = nil, item: String? = nil, warning: String? = nil,
                         before: Double = .infinity, estimator: (String) -> Int) {
        let keys = pending.filter { (thread == nil || $0.value.thread == thread) && (turn == nil || $0.value.turn == turn) && (item == nil || $0.value.item == item) && $0.value.last <= before }.map(\.key)
        for key in keys {
            guard let p = pending.removeValue(forKey: key), p.chunks >= 2, p.last > p.first else { continue }
            startedItems.remove("\(p.thread)/\(p.item)")
            let count = max(0, estimator(p.text) - estimator(p.firstText))
            // The first received chunk has no observed production interval. Exclude it from the numerator.
            let duration = p.last - p.first
            let problem = warning ?? (!p.sawStart ? "未见流开始标记，可能只采到中途片段" : nil) ?? (p.truncated ? "输出超过采样上限" : (p.maxGap > 2 ? "接收间隔超过 2 秒，可能受网络或服务端停顿影响" : nil))
            let confidence = problem != nil ? "low" : (count >= 500 && duration >= 5 && p.chunks >= 10 ? "high" : (count >= 100 && duration >= 2 && p.chunks >= 4 ? "medium" : "low"))
            let sample = ObservedSpeedSample(id: "\(key)/\(p.first)/\(p.last)", threadID: p.thread, turnID: p.turn, itemID: p.item,
                model: p.model, startedAt: p.first, endedAt: p.last, outputTokens: count,
                outputCharacters: max(0, p.text.count - p.firstText.count), outputBytes: max(0, p.text.utf8.count - p.firstText.utf8.count), chunkCount: p.chunks, durationSeconds: duration,
                tokensPerSecond: Double(count) / duration, confidence: confidence,
                networkWarning: problem, source: p.source)
            samples.removeAll { $0.id == sample.id }; samples.append(sample); revision += 1
        }
        samples = Array(samples.suffix(10_000))
    }
    mutating func addCompletedBodies(_ values: [ObservedSpeedSample]) {
        guard !values.isEmpty else { return }
        var indices = Dictionary(samples.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
        for sample in values where sample.measurementKind == "completed_body" && sample.tokensPerSecond.isFinite && sample.durationSeconds > 0 {
            if let index = indices[sample.id] {
                if samples[index].bodyPhase == nil, let phase = sample.bodyPhase {
                    samples[index].bodyPhase = phase; revision += 1
                }
            } else { indices[sample.id] = samples.count; samples.append(sample); revision += 1 }
        }
    }
    mutating func pruneCompletedBodies(now: Double, retentionDays: Int) {
        guard now.isFinite, [15, 30].contains(retentionDays) else { return }
        let count = samples.count
        samples.removeAll { $0.isBody && $0.endedAt < now - Double(retentionDays * 86400) }
        if samples.count != count { revision += 1 }
    }
    /// Only eligible completed bodies; saved historical stream records remain untouched.
    func completedBodySummaries(now: Double, windowSeconds: Double) -> [ModelSpeedSummary] {
        let rows = samples.filter {
            $0.isBody && $0.bodyQuality.included
                && $0.endedAt >= now - windowSeconds && $0.endedAt <= now
                && $0.hasKnownModel
                && $0.durationSeconds > 0 && $0.durationSeconds.isFinite && $0.tokensPerSecond.isFinite
        }
        return Dictionary(grouping: rows, by: \.model).map { model, parts in
            let tokens = parts.reduce(0) { $0 + $1.outputTokens }, duration = parts.reduce(0.0) { $0 + $1.durationSeconds }
            var result = ModelSpeedSummary(model: model, tokensPerSecond: Double(tokens) / duration,
                sampleCount: parts.count, outputTokens: tokens, durationSeconds: duration)
            result.qualifiedSampleCount = parts.count
            result.confidence = duration >= 5 ? "high" : "medium"
            result.lastMeasuredAt = parts.map(\.endedAt).max()
            return result
        }.sorted { $0.sampleCount == $1.sampleCount ? $0.model < $1.model : $0.sampleCount > $1.sampleCount }
    }
    /// Latest qualified body per model, independent of the main page averaging window.
    func latestCompletedBodySpeeds(now: Double, windowSeconds: Double = 1800) -> [ModelSpeedSummary] {
        var latest: [String: ObservedSpeedSample] = [:]
        for row in samples where row.isBody && row.hasKnownModel && row.bodyQuality.included
            && row.endedAt >= now - windowSeconds && row.endedAt <= now {
            if let previous = latest[row.model], previous.endedAt > row.endedAt
                || (previous.endedAt == row.endedAt && previous.id < row.id) { continue }
            latest[row.model] = row
        }
        return latest.values.sorted {
            $0.endedAt == $1.endedAt ? $0.model < $1.model : $0.endedAt > $1.endedAt
        }.map { row in
            ModelSpeedSummary(model: row.model, tokensPerSecond: row.tokensPerSecond,
                sampleCount: 1, outputTokens: row.outputTokens, durationSeconds: row.durationSeconds,
                qualifiedSampleCount: 1, confidence: row.bodyQuality.confidence, lastMeasuredAt: row.endedAt)
        }
    }
    func summaries(now: Double, windowSeconds: Double = 7 * 86400) -> [ModelSpeedSummary] {
        displaySummaries(now: now, windowSeconds: windowSeconds, includeShortAndActive: false)
    }
    /// Display all complete, uninterrupted short segments as well as current receipt samples.
    /// The strict long-sample summary remains available through summaries().
    func displaySummaries(now: Double, windowSeconds: Double, includeShortAndActive: Bool = true) -> [ModelSpeedSummary] {
        struct Part { var model: String; var tokens: Int; var duration: Double; var chunks: Int; var active: Bool; var qualified: Bool }
        var parts = samples.filter {
            $0.endedAt >= now - windowSeconds && $0.endedAt <= now && $0.networkWarning == nil
                && $0.model != "unknown" && !$0.model.isEmpty && $0.durationSeconds > 0 && $0.durationSeconds.isFinite
                && (includeShortAndActive || $0.confidence != "low")
        }.map { Part(model: $0.model, tokens: $0.outputTokens, duration: $0.durationSeconds,
            chunks: $0.chunkCount, active: false, qualified: $0.confidence != "low") }
        parts += pending.values.filter {
            includeShortAndActive && $0.last >= now - min(windowSeconds, 2) && $0.last <= now && $0.last > $0.first
                && $0.chunks >= 2 && $0.sawStart && !$0.truncated && $0.maxGap <= 2
                && $0.model != "unknown" && !$0.model.isEmpty
        }.map { Part(model: $0.model, tokens: $0.liveTokens, duration: $0.last - $0.first,
            chunks: $0.chunks, active: true, qualified: false) }
        return Dictionary(grouping: parts, by: \.model).map { model, rows in
            let tokens = rows.reduce(0) { $0 + $1.tokens }, duration = rows.reduce(0.0) { $0 + $1.duration }
            let chunks = rows.reduce(0) { $0 + $1.chunks }
            var result = ModelSpeedSummary(model: model, tokensPerSecond: Double(tokens) / duration,
                sampleCount: rows.count, outputTokens: tokens, durationSeconds: duration)
            result.activeSampleCount = rows.filter(\.active).count
            result.qualifiedSampleCount = rows.filter(\.qualified).count
            result.confidence = tokens >= 500 && duration >= 5 && chunks >= 10 ? "high" : (tokens >= 100 && duration >= 2 && chunks >= 4 ? "medium" : "low")
            return result
        }.sorted { $0.sampleCount == $1.sampleCount ? $0.model < $1.model : $0.sampleCount > $1.sampleCount }
    }
    mutating func resolveModels(_ models: [String: [String: String]]) {
        var changed = false
        for index in samples.indices where samples[index].model.isEmpty || samples[index].model == "unknown" {
            if let model = models[samples[index].threadID]?[samples[index].turnID] {
                samples[index].model = model; changed = true
            }
        }
        for key in Array(pending.keys) {
            guard var part = pending[key], part.model.isEmpty || part.model == "unknown",
                  let model = models[part.thread]?[part.turn] else { continue }
            part.model = model; pending[key] = part
        }
        if changed { revision += 1 }
    }
    static func sourceKey(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
    mutating func persist() {
        guard let storeURL, canPersist else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: storeURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "测速记录保存失败：\(error.localizedDescription)" }
    }
}

/// Persist body measurements in SQLite off the main actor. Tickets prevent an older
/// queued revision from overwriting a newer one after a source switch.
actor BodySpeedSampleWriter {
    private struct StoreCache {
        let store: BodySpeedTrendStore
        var persistedByID: [String: ObservedSpeedSample]
        var retentionDays: Int
    }

    private var caches: [URL: StoreCache] = [:]
    /// Tracks the last committed revision only. A failed write leaves the ticket retryable.
    private var tickets: [URL: Int] = [:]

    func load(from url: URL, now: Double, retentionDays: Int = 30) throws -> [ObservedSpeedSample] {
        let key = url.standardizedFileURL
        var cache = try storeCache(for: key, now: now, retentionDays: retentionDays)
        let samples = try cache.store.loadSamples(now: now, retentionDays: retentionDays)
        cache.persistedByID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        caches[key] = cache
        return samples
    }

    func persist(
        _ samples: [ObservedSpeedSample],
        to url: URL,
        ticket: Int,
        now: Double = Date().timeIntervalSince1970,
        retentionDays: Int = 30
    ) -> String? {
        let key = url.standardizedFileURL
        guard ticket > (tickets[key] ?? -1) else { return nil }
        do {
            var cache = try storeCache(for: key, now: now, retentionDays: retentionDays)
            var incomingByID: [String: ObservedSpeedSample] = [:]
            for sample in samples where sample.isBody {
                incomingByID[sample.id] = sample
            }
            let changed = incomingByID.values
                .filter { cache.persistedByID[$0.id] != $0 }
                .sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt < $1.endedAt }

            let cutoff = now - Double([15, 30].contains(retentionDays) ? retentionDays : 30) * 86_400
            let hasExpiredRaw = cache.persistedByID.values.contains { $0.endedAt < cutoff }
            let normalizedRetention = [15, 30].contains(retentionDays) ? retentionDays : 30
            if !changed.isEmpty || hasExpiredRaw || cache.retentionDays != normalizedRetention {
                try cache.store.ingest(samples: changed, now: now, retentionDays: retentionDays)
                cache.retentionDays = normalizedRetention
            }
            cache.persistedByID = cache.persistedByID.filter { $0.value.endedAt >= cutoff && $0.value.endedAt <= now }
            for sample in changed where sample.endedAt >= cutoff && sample.endedAt <= now {
                cache.persistedByID[sample.id] = sample
            }
            caches[key] = cache
            tickets[key] = ticket
            return nil
        } catch {
            return "测速记录保存失败：\(error.localizedDescription)"
        }
    }

    func trend(from url: URL, now: Double, days: Int) throws -> [BodySpeedTrendPoint] {
        let key = url.standardizedFileURL
        var cache = try storeCache(for: key, now: now, retentionDays: 30)
        let points = try cache.store.read(now: now, days: days)
        caches[key] = cache
        return points
    }

    private func storeCache(for url: URL, now: Double, retentionDays: Int) throws -> StoreCache {
        if let cache = caches[url] { return cache }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try BodySpeedTrendStore(url: url)
        let samples = try store.loadSamples(now: now, retentionDays: retentionDays)
        return StoreCache(
            store: store,
            persistedByID: Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
            retentionDays: try store.retentionDays()
        )
    }
}

/// Associates receipt timestamps with explicit local turn boundaries, including short adjacent turns.
/// A currently selected turn alone is not sufficient evidence for historical delta attribution.
struct ObservedStreamContexts {
    struct Context {
        var turn: String
        var model: String
        var start: Double
        var end: Double?
    }
    var threads: [String: [Context]] = [:]
    mutating func consume(_ signal: ThroughputSignal, thread: String) {
        guard !signal.turnID.isEmpty, signal.timestamp.isFinite else { return }
        var contexts = threads[thread] ?? []
        if signal.kind == "start" || signal.kind == "context" {
            if let index = contexts.firstIndex(where: { $0.turn == signal.turnID }) {
                contexts[index].start = min(contexts[index].start, signal.timestamp)
                if !signal.model.isEmpty { contexts[index].model = signal.model }
            } else {
                contexts.append(Context(turn: signal.turnID, model: signal.model.isEmpty ? "unknown" : signal.model, start: signal.timestamp))
            }
        } else if ["complete", "abort", "failure"].contains(signal.kind),
                  let index = contexts.firstIndex(where: { $0.turn == signal.turnID }) {
            contexts[index].end = signal.timestamp
        }
        contexts.sort { $0.start < $1.start }
        threads[thread] = Array(contexts.suffix(16))
        if threads.count > 256 { threads.removeValue(forKey: threads.min { ($0.value.last?.start ?? 0) < ($1.value.last?.start ?? 0) }!.key) }
    }
    func resolve(thread: String, at: Double, explicitTurn: String?) -> (turn: String, model: String)? {
        let contexts = threads[thread] ?? []
        if let explicitTurn, !explicitTurn.isEmpty {
            let model = contexts.last { $0.turn == explicitTurn }?.model ?? "unknown"
            return (explicitTurn, model)
        }
        guard let context = contexts.last(where: { $0.start <= at && ($0.end == nil || at <= $0.end!) }) else { return nil }
        return (context.turn, context.model)
    }
}
