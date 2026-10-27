import Foundation

/// A model call past omp's own statistics guard: `model`, `provider` and `api` are strings and `usage` is an object
/// (METRICS 4.7). Assistant messages and `model_usage` entries share it.
struct OmpCall: Equatable, Sendable {
    var model: String
    /// The `provider` string; nil when it is empty (METRICS 3.2).
    var provider: String?
    var tokens: TokenUsage
    /// One of `input`, `output`, `cacheRead`, `cacheWrite` is above 0.
    var hasUsage: Bool
    var modes: ExecutionModes = .empty
}

/// `message.stopReason`; a missing or non-string value counts as `aborted`.
enum OmpStop: Equatable, Sendable {
    case aborted
    case error
    case stop
    case toolUse
    case length
    case other

    var isFailure: Bool { self == .aborted || self == .error }
}

struct OmpAssistant: Equatable, Sendable {
    var call: OmpCall
    /// `message.timestamp` truncated, when it is a finite number above 0.
    var startedMs: Int64?
    /// `message.duration` truncated, when it is a finite number of at least 0.
    var durationMs: Int64?
    /// `message.completedAt` truncated, when it is a finite number above 0.
    var completedAtMs: Int64?
    var stop: OmpStop
    /// `message.stopDetails.type == "pause_turn"`.
    var pausesTurn = false
    /// String ids of the `toolCall` blocks of `message.content`.
    var toolCallIds: Set<String> = []
}

enum OmpRecord: Equatable, Sendable {
    /// A `user` or `developer` message.
    case input
    case assistant(OmpAssistant)
    /// `isFinalYield`: `toolName == "yield"` and `isError` is not `true`.
    case toolResult(callId: String?, isFinalYield: Bool)
    /// A side call.
    case modelUsage(OmpCall)
    /// `custom` with `customType == "session_exit"`.
    case sessionExit
    case modeChange([String: String])
    /// Anything else, including calls that fail the guard: only `lastLineMs`.
    case other
}

struct OmpSession: Equatable, Sendable {
    var id: String?
    var timestampMs: Int64?
    var cwd: String?
}

/// One classified line of an omp session file (METRICS 4.7).
enum OmpLine: Equatable, Sendable {
    /// A `session` line.
    case header(OmpSession)
    /// An entry with a string `id` and a parseable `timestamp`.
    case entry(id: String, timestampMs: Int64, record: OmpRecord, parentId: String? = nil)
    /// The title slot, and entries without a string `id` or a parseable `timestamp`.
    case ignored
}

/// Decodes omp session lines. Conversation content is skipped (only validated). Repeated members resolve like
/// Python's `json.loads`: the last one wins.
enum OmpLineExtractor {
    private static let types: [StaticString] = ["title", "session", "message", "model_usage", "custom", "service_tier_change"]
    private static let roles: [StaticString] = ["user", "developer", "assistant", "toolResult"]
    private static let stopReasons: [StaticString] = ["aborted", "error", "stop", "toolUse", "length"]

    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<OmpLine> {
        if isBlank(bytes) { return .blank }
        var scanner = JSONScanner(bytes)
        do {
            try scanner.beginObject()
            let top = try scanTopLevel(&scanner)
            try scanner.finish()
            return .line(top.classified())
        } catch {
            return .malformed
        }
    }

    /// Python's `bytes.strip()` whitespace, which also covers vertical tab and form feed.
    private static func isBlank(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.allSatisfy { $0 == UInt8(ascii: " ") || (0x09...0x0D).contains($0) }
    }

    // MARK: - Members

    private struct Usage {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0
    }

    private struct CallMembers {
        var model: String?
        var hasProvider = false
        var provider: String?
        var hasApi = false
        var usage: Usage?
        var serviceTier: String?

        func call() -> OmpCall? {
            guard let model, hasProvider, hasApi, let usage else { return nil }
            let tokens = TokenUsage(
                input: TokenCount.sum(usage.input, usage.cacheRead, usage.cacheWrite),
                cachedInput: usage.cacheRead,
                cacheWriteInput: usage.cacheWrite,
                output: usage.output,
                reasoning: usage.reasoning
            )
            let hasUsage = usage.input > 0 || usage.output > 0 || usage.cacheRead > 0 || usage.cacheWrite > 0
            return OmpCall(model: model, provider: provider, tokens: tokens, hasUsage: hasUsage,
                           modes: ExecutionModeAdapters.omp(serviceTier, provider: provider, evidence: .recorded, scope: .response))
        }
    }

    private struct MessageMembers {
        var role: Int?
        var call = CallMembers()
        var timestamp: JSONNumber?
        var duration: JSONNumber?
        var completedAt: JSONNumber?
        var stopReason: Int?
        var pausesTurn = false
        var toolCallIds: Set<String> = []
        var toolCallId: String?
        var isYield = false
        var isErrorTrue = false

        func record() -> OmpRecord {
            switch role {
            case 0, 1:
                return .input
            case 2:
                guard let call = call.call() else { return .other }
                return .assistant(OmpAssistant(
                    call: call,
                    startedMs: timestamp.flatMap(Self.positive),
                    durationMs: duration.flatMap { $0.isFinite && $0.isNonNegative ? $0.truncated : nil },
                    completedAtMs: completedAt.flatMap(Self.positive),
                    stop: stop,
                    pausesTurn: pausesTurn,
                    toolCallIds: toolCallIds
                ))
            case 3:
                return .toolResult(callId: toolCallId, isFinalYield: isYield && !isErrorTrue)
            default:
                return .other
            }
        }

        private var stop: OmpStop {
            switch stopReason {
            case nil, 0: .aborted
            case 1: .error
            case 2: .stop
            case 3: .toolUse
            case 4: .length
            default: .other
            }
        }

        private static func positive(_ number: JSONNumber) -> Int64? {
            number.isFinite && number.isPositive ? number.truncated : nil
        }
    }

    private struct TopLevel {
        var type: Int?
        var id: String?
        var parentId: String?
        var tiers: [String: String] = [:]
        var timestampMs: Int64?
        var cwd: String?
        var message: MessageMembers?
        var call = CallMembers()
        var isSessionExit = false

        func classified() -> OmpLine {
            switch type {
            case 0:
                return .ignored
            case 1:
                return .header(OmpSession(id: id, timestampMs: timestampMs, cwd: cwd))
            default:
                break
            }
            guard let id, let timestampMs else { return .ignored }
            let record: OmpRecord = switch type {
            case 2: message?.record() ?? .other
            case 3: call.call().map(OmpRecord.modelUsage) ?? .other
            case 4: isSessionExit ? .sessionExit : .other
            case 5: .modeChange(tiers)
            default: .other
            }
            return .entry(id: id, timestampMs: timestampMs, record: record, parentId: parentId)
        }
    }

    // MARK: - Scanning

    private static func scanTopLevel(_ scanner: inout JSONScanner) throws(JSONScanError) -> TopLevel {
        var top = TopLevel()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "type") {
                top.type = try scanner.readStringMatch(types)
            } else if scanner.key(key, is: "id") {
                top.id = try scanner.readString()
            } else if scanner.key(key, is: "parentId") {
                top.parentId = try scanner.readString()
            } else if scanner.key(key, is: "serviceTier") {
                top.tiers = [:]
                guard try scanner.beginObjectIfPresent() else { continue }
                while let tierKey = try scanner.nextMember() {
                    let family: String? = scanner.key(tierKey, is: "openai") ? "openai"
                        : scanner.key(tierKey, is: "anthropic") ? "anthropic" : scanner.key(tierKey, is: "google") ? "google" : nil
                    if let family { top.tiers[family] = try scanner.readString() }
                    else { try scanner.skipValue() }
                }
            } else if scanner.key(key, is: "timestamp") {
                top.timestampMs = try scanner.readTimestamp()
            } else if scanner.key(key, is: "cwd") {
                top.cwd = try scanner.readString()
            } else if scanner.key(key, is: "message") {
                top.message = try scanMessage(&scanner)
            } else if scanner.key(key, is: "customType") {
                top.isSessionExit = try scanner.readStringMatch(["session_exit"]) == 0
            } else if try !scanCallMember(key, &scanner, into: &top.call) {
                try scanner.skipValue()
            }
        }
        return top
    }

    private static func scanMessage(_ scanner: inout JSONScanner) throws(JSONScanError) -> MessageMembers? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var message = MessageMembers()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "role") {
                message.role = try scanner.readStringMatch(roles)
            } else if scanner.key(key, is: "timestamp") {
                message.timestamp = try scanner.readNumber()
            } else if scanner.key(key, is: "duration") {
                message.duration = try scanner.readNumber()
            } else if scanner.key(key, is: "completedAt") {
                message.completedAt = try scanner.readNumber()
            } else if scanner.key(key, is: "stopReason") {
                message.stopReason = try scanner.readStringMatch(stopReasons)
            } else if scanner.key(key, is: "stopDetails") {
                message.pausesTurn = try scanPausesTurn(&scanner)
            } else if scanner.key(key, is: "content") {
                message.toolCallIds = try scanToolCallIds(&scanner)
            } else if scanner.key(key, is: "toolCallId") {
                message.toolCallId = try scanner.readString()
            } else if scanner.key(key, is: "toolName") {
                message.isYield = try scanner.readStringMatch(["yield"]) == 0
            } else if scanner.key(key, is: "isError") {
                message.isErrorTrue = try scanner.readBool() == true
            } else if try !scanCallMember(key, &scanner, into: &message.call) {
                try scanner.skipValue()
            }
        }
        return message
    }

    /// Reads one member of a model call; returns false (consuming nothing) for any other key.
    private static func scanCallMember(
        _ key: JSONKey,
        _ scanner: inout JSONScanner,
        into call: inout CallMembers
    ) throws(JSONScanError) -> Bool {
        if scanner.key(key, is: "model") {
            call.model = try scanner.readString()
        } else if scanner.key(key, is: "provider") {
            let value = try scanner.readStringValue()
            call.hasProvider = value != nil
            call.provider = value.flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        } else if scanner.key(key, is: "api") {
            call.hasApi = try scanner.readStringIsNonEmpty() != nil
        } else if scanner.key(key, is: "serviceTier") {
            call.serviceTier = try scanner.readString()
        } else if scanner.key(key, is: "usage") {
            call.usage = try scanUsage(&scanner)
        } else {
            return false
        }
        return true
    }

    /// omp's normalized `Usage`; missing, non-numeric and negative fields are 0 (METRICS 4.7).
    private static func scanUsage(_ scanner: inout JSONScanner) throws(JSONScanError) -> Usage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var usage = Usage()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "input") {
                usage.input = TokenCount.clamp(try scanner.readNumber()?.truncated)
            } else if scanner.key(key, is: "output") {
                usage.output = TokenCount.clamp(try scanner.readNumber()?.truncated)
            } else if scanner.key(key, is: "cacheRead") {
                usage.cacheRead = TokenCount.clamp(try scanner.readNumber()?.truncated)
            } else if scanner.key(key, is: "cacheWrite") {
                usage.cacheWrite = TokenCount.clamp(try scanner.readNumber()?.truncated)
            } else if scanner.key(key, is: "reasoningTokens") {
                usage.reasoning = TokenCount.clamp(try scanner.readNumber()?.truncated)
            } else {
                try scanner.skipValue()
            }
        }
        return usage
    }

    private static func scanPausesTurn(_ scanner: inout JSONScanner) throws(JSONScanError) -> Bool {
        guard try scanner.beginObjectIfPresent() else { return false }
        var pauses = false
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "type") {
                pauses = try scanner.readStringMatch(["pause_turn"]) == 0
            } else {
                try scanner.skipValue()
            }
        }
        return pauses
    }

    /// Blocks of type `toolCall` with a string `id`; any other `content` value has none.
    private static func scanToolCallIds(_ scanner: inout JSONScanner) throws(JSONScanError) -> Set<String> {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return []
        }
        var ids: Set<String> = []
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            var isToolCall = false
            var id: String?
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "type") {
                    isToolCall = try scanner.readStringMatch(["toolCall"]) == 0
                } else if scanner.key(key, is: "id") {
                    id = try scanner.readString()
                } else {
                    try scanner.skipValue()
                }
            }
            if isToolCall, let id { ids.insert(id) }
        }
        return ids
    }
}
