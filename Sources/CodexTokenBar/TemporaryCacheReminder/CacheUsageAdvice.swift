import Foundation
import CoreFoundation

/// Temporary transition feature. Disabling this gate suppresses sampling and UI;
/// it has no scanner, persistence, ledger, or follow-up recommendation dependency.
enum CacheMissReminderFeature { static let isEnabled = true }


/// Observational only: never enters the precise ledger or rate accumulator.
struct CacheUsageSample: Sendable {
    enum Boundary: Sendable { case started, completed }
    var timestamp: TimeInterval
    var model: String?
    var context = false
    var reset = false
    var input: UInt64?
    var cached: UInt64?
    var total: UInt64?
    var requestID: String?
    var boundary: Boundary?
    var turnID: String?

    static func parse(object: [String: Any], payload: [String: Any], timestamp: TimeInterval) -> Self? {
        guard CacheMissReminderFeature.isEnabled else { return nil }
        let type = object["type"] as? String
        let kind = payload["type"] as? String
        if type == "event_msg", kind == "task_started" || kind == "task_complete" {
            let eventTime = Self.eventTime(payload[kind == "task_started" ? "started_at" : "completed_at"]) ?? timestamp
            return Self(timestamp: eventTime, boundary: kind == "task_started" ? .started : .completed, turnID: payload["turn_id"] as? String)
        }
        if type == "turn_context" {
            return Self(timestamp: timestamp, model: payload["model"] as? String, context: true)
        }
        if type == "compacted" || kind == "context_compacted" || kind == "thread_rolled_back" {
            return Self(timestamp: timestamp, reset: true)
        }
        guard type == "event_msg", kind == "token_count" else { return nil }
        let info = payload["info"] as? [String: Any]
        let last = info?["last_token_usage"] as? [String: Any]
        let total = info?["total_token_usage"] as? [String: Any]
        let requestID = [payload["response_id"], payload["request_id"], object["response_id"], object["request_id"], info?["response_id"], info?["request_id"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
        return Self(timestamp: timestamp, input: integer(last?["input_tokens"]),
                    cached: integer(last?["cached_input_tokens"]), total: integer(total?["total_tokens"]),
                    requestID: requestID)
    }

    private static func eventTime(_ value: Any?) -> TimeInterval? {
        if let text = value as? String {
            let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text))
            return date?.timeIntervalSince1970
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              !number.stringValue.hasPrefix("-") else { return nil }
        return UInt64(number.stringValue)
    }
}

struct CacheUsageAdvice: Equatable, Sendable {
    var threadID: String
    var hitRate: Double
    var low: Bool
    var timestamp: TimeInterval
    var affectedThreads: Int = 0
    var threadTitle: String? = nil
    var idleGapSeconds: TimeInterval? = nil
    var model: String? = nil

    var displayTitle: String {
        let title = threadTitle?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return title.isEmpty ? "无标题会话" : title
    }

    var presentationID: String { "\(threadID):\(timestamp)" }
    var hasValidHitRate: Bool { hitRate.isFinite && (0...1).contains(hitRate) }

    func shouldRemind(enabled: Bool, dismissedID: String = "", now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        enabled && low && hasValidHitRate && timestamp.isFinite && timestamp >= 0
            && now >= timestamp && now - timestamp <= 120 && presentationID != dismissedID
    }
}

struct CacheUsageAdviceTracker {
    private struct State {
        var model: String?
        var total: UInt64?
        var requests = RecentFingerprintSet(limit: 128)
        var advice: CacheUsageAdvice?
        var touched: TimeInterval = 0
        var hasObservedRequest = false
        var lastCompleted: TimeInterval?
        var currentTurnID: String?
        var gap: TimeInterval?
    }
    private var states: [String: State] = [:]

    mutating func reset(threadID: String) { states.removeValue(forKey: threadID) }

    mutating func consume(_ sample: CacheUsageSample, threadID: String, now: TimeInterval,
                          monotonic _: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard CacheMissReminderFeature.isEnabled else { states.removeAll(); return }
        if sample.reset { reset(threadID: threadID); return }
        var state = states[threadID] ?? State()
        defer {
            state.touched = now
            states[threadID] = state
            if states.count > 64, let oldest = states.min(by: { $0.value.touched < $1.value.touched })?.key {
                states.removeValue(forKey: oldest)
            }
        }
        if let boundary = sample.boundary {
            guard sample.timestamp.isFinite, sample.timestamp >= 0, sample.timestamp <= now + 1, let id = sample.turnID, !id.isEmpty else { return }
            switch boundary {
            case .started:
                if state.currentTurnID != id {
                    state.currentTurnID = id
                    state.gap = state.lastCompleted.flatMap { sample.timestamp >= $0 ? sample.timestamp - $0 : nil }
                    state.lastCompleted = nil
                }
            case .completed:
                if state.currentTurnID == nil || state.currentTurnID == id { state.lastCompleted = sample.timestamp }
            }
            return
        }
        if sample.context {
            if state.model != sample.model {
                let previous = state
                state = State(model: sample.model, hasObservedRequest: state.hasObservedRequest)
                state.lastCompleted = previous.lastCompleted; state.currentTurnID = previous.currentTurnID; state.gap = previous.gap
            }
            return
        }
        // A record can land while the existing poll is reading. Retain up to
        // one second of skew; latest() will not display it before its timestamp.
        guard sample.timestamp.isFinite, sample.timestamp >= 0, sample.timestamp <= now + 1, now - sample.timestamp <= 120 else {
            state.advice = nil; return
        }
        guard let input = sample.input, let cached = sample.cached, input > 0, cached <= input else {
            state.advice = nil; return
        }
        // A cumulative watermark confirms independence even if identical request
        // usage is repeated. A transport offset alone cannot establish this.
        let requestIsNew = sample.requestID.map { !$0.isEmpty && !state.requests.contains($0) } ?? false
        if let request = sample.requestID, !request.isEmpty, !requestIsNew { return }
        if let total = sample.total, let previous = state.total {
            if total == previous && !requestIsNew { return }
            if total < previous { state.advice = nil; state.total = total; state.hasObservedRequest = true; return }
        }
        if let request = sample.requestID, !request.isEmpty {
            guard state.requests.insertIfNew(request) else { return }
        }
        state.total = sample.total ?? state.total
        let ratio = Double(cached) / Double(input)
        // The first request in a new or compacted context cannot have a warm cache.
        let low = state.hasObservedRequest && input >= 20_000 && ratio < 0.3
        state.hasObservedRequest = true
        state.advice = CacheUsageAdvice(threadID: threadID, hitRate: ratio, low: low, timestamp: sample.timestamp,
            idleGapSeconds: state.gap, model: state.model)
    }

    func latest(now: TimeInterval, threadID: String? = nil) -> CacheUsageAdvice? {
        guard CacheMissReminderFeature.isEnabled else { return nil }
        let fresh = states.values.compactMap(\.advice).filter {
            now >= $0.timestamp && now - $0.timestamp <= 120 && (threadID == nil || $0.threadID == threadID)
        }
        var latest = fresh.max { left, right in
            left.low == right.low ? left.timestamp < right.timestamp : !left.low
        }
        latest?.affectedThreads = fresh.filter(\.low).count
        return latest
    }
}
