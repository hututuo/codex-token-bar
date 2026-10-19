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
    var total: Double { sessions.values.reduce(0) { $0 + $1.display } }
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
}
struct ModelSpeedSummary: Equatable, Identifiable {
    var model: String
    var tokensPerSecond: Double
    var sampleCount: Int
    var outputTokens: Int
    var durationSeconds: Double
    var id: String { model }
}

/// Receipt timing is measured; local tokenizer output is an estimate, not billable usage.
struct ObservedSpeedCollector {
    struct Pending {
        var thread: String; var turn: String; var item: String; var model: String
        var first: Double; var last: Double
        var firstText = ""; var text = ""; var chunks = 0; var maxGap = 0.0; var truncated = false; var sawStart = false
    }
    var pending: [String: Pending] = [:]
    var startedItems: Set<String> = []
    var samples: [ObservedSpeedSample] = []
    var revision = 0
    var persistenceError: String?
    var storeURL: URL?
    private var canPersist = true

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                samples = Array(try JSONDecoder().decode([ObservedSpeedSample].self, from: data).suffix(10_000))
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
    mutating func append(thread: String, turn: String, item: String, model: String, text: String, at: Double) {
        guard !text.isEmpty, !thread.isEmpty, !turn.isEmpty, !item.isEmpty, item != "unknown" else { return }
        let key = "\(thread)/\(turn)/\(item)"
        var p = pending[key] ?? Pending(thread: thread, turn: turn, item: item, model: model, first: at, last: at)
        guard at >= p.last else { return }
        if !model.isEmpty, model != "unknown" { p.model = model }
        if p.chunks == 0 { p.firstText = text; p.sawStart = startedItems.contains("\(thread)/\(item)") }
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
                networkWarning: problem, source: "Codex 本地流式增量 · 接收计时 / 本地分词估算")
            samples.removeAll { $0.id == sample.id }; samples.append(sample); revision += 1
        }
        samples = Array(samples.suffix(10_000))
    }
    func summaries(now: Double, windowSeconds: Double = 7 * 86400) -> [ModelSpeedSummary] {
        Dictionary(grouping: samples.filter { $0.endedAt >= now - windowSeconds && $0.endedAt <= now && $0.networkWarning == nil && $0.confidence != "low" && $0.model != "unknown" }, by: \.model)
            .map { model, records in
                let tokens = records.reduce(0) { $0 + $1.outputTokens }
                let duration = records.reduce(0.0) { $0 + $1.durationSeconds }
                return ModelSpeedSummary(model: model, tokensPerSecond: Double(tokens) / max(0.001, duration), sampleCount: records.count, outputTokens: tokens, durationSeconds: duration)
            }.sorted { $0.sampleCount > $1.sampleCount }
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
