import Foundation

/// What a WorkBuddy line is to the state machine (METRICS 4.9 Line format and classification).
enum WorkBuddyItem: Equatable, Sendable {
    case userMessage
    case assistantMessage
    case functionCall
    case functionCallResult
    case reasoning
    case modelUsage
    /// Every other line: only `lastLineMs` and `cwd`.
    case other

    var isOutput: Bool {
        switch self {
        case .assistantMessage, .functionCall, .reasoning, .modelUsage: true
        case .userMessage, .functionCallResult, .other: false
        }
    }
}

/// The model call an output item or `model-usage` line belongs to.
struct WorkBuddyCall: Equatable, Sendable {
    /// `providerData.messageId` when it is a non-empty string.
    var messageId: String?
    /// Normalized usage; nil when neither `usage` nor `rawUsage` is an object.
    var tokens: TokenUsage?
    /// The stream's model, else the requested id; trimmed, without a user-provider prefix.
    var model: String?
    /// `custom` for a model of the user's own provider (`custom:` / `custom-local:` ids).
    var provider: String?
    var modes: ExecutionModes = .empty
}

/// One WorkBuddy session line. Content, arguments and tool output are never captured.
struct WorkBuddyLine: Equatable, Sendable {
    /// Nil when the line has no valid timestamp; such a line is ignored entirely.
    var timestampMs: Int64?
    /// A string `cwd` with visible text.
    var cwd: String?
    var item: WorkBuddyItem = .other
    /// The line's `id` when it is a non-empty string.
    var id: String?
    var callId: String?
    /// `status == "incomplete"`
    var isIncomplete = false
    /// `providerData.skipRun == true`
    var skipRun = false
    /// `providerData.isPartialAborted == true`
    var isPartialAborted = false
    /// `providerData.error` is an object.
    var hasError = false
    /// `providerData.agent == "compact"`
    var isCompaction = false
    var call = WorkBuddyCall()
}

/// Decodes WorkBuddy session lines (METRICS 4.9). Repeated members resolve like Python's `json.loads`: the last one wins.
enum WorkBuddyLineExtractor {
    private static let types: [StaticString] = ["message", "function_call_result", "function_call", "reasoning", "model-usage"]
    private static let roles: [StaticString] = ["user", "assistant"]
    private static let userPrefixes = ["custom:", "custom-local:"]

    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<WorkBuddyLine> {
        if isBlank(bytes) { return .blank }
        var scanner = JSONScanner(bytes)
        do {
            try scanner.beginObject()
            let line = try scanTopLevel(&scanner)
            try scanner.finish()
            return .line(line)
        } catch {
            return .malformed
        }
    }

    /// Python's `bytes.strip()` whitespace, which also covers vertical tab and form feed.
    private static func isBlank(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.allSatisfy { $0 == UInt8(ascii: " ") || (0x09...0x0D).contains($0) }
    }

    // MARK: - Members

    private struct ProviderData {
        var skipRun = false
        var isPartialAborted = false
        var hasError = false
        var isCompaction = false
        var messageId: String?
        var model: String?
        var requestModelId: String?
        var usage: WorkBuddyAgentsUsage?
        var rawUsage: WorkBuddyRawUsage?
    }

    private static func scanTopLevel(_ scanner: inout JSONScanner) throws(JSONScanError) -> WorkBuddyLine {
        var line = WorkBuddyLine()
        var type: Int?
        var role: Int?
        var provider: ProviderData?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "timestamp") {
                line.timestampMs = try readTimestamp(&scanner)
            } else if scanner.key(key, is: "type") {
                type = try scanner.readStringMatch(types)
            } else if scanner.key(key, is: "role") {
                role = try scanner.readStringMatch(roles)
            } else if scanner.key(key, is: "status") {
                line.isIncomplete = try scanner.readStringMatch(["incomplete"]) == 0
            } else if scanner.key(key, is: "id") {
                line.id = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "callId") {
                line.callId = try scanner.readString()
            } else if scanner.key(key, is: "cwd") {
                line.cwd = try scanner.readString().flatMap { hasVisibleText($0) ? $0 : nil }
            } else if scanner.key(key, is: "providerData") {
                provider = try scanProviderData(&scanner)
            } else {
                try scanner.skipValue()
            }
        }
        line.item = switch (type, role) {
        case (0, 0): .userMessage
        case (0, 1): .assistantMessage
        case (1, _): .functionCallResult
        case (2, _): .functionCall
        case (3, _): .reasoning
        case (4, _): .modelUsage
        default: .other
        }
        if let provider {
            line.skipRun = provider.skipRun
            line.isPartialAborted = provider.isPartialAborted
            line.hasError = provider.hasError
            line.isCompaction = provider.isCompaction
            line.call = call(from: provider)
        }
        return line
    }

    /// A finite number above 0 (truncated), or an RFC 3339 string.
    private static func readTimestamp(_ scanner: inout JSONScanner) throws(JSONScanError) -> Int64? {
        if scanner.nextIsString { return try scanner.readTimestamp() }
        guard let number = try scanner.readNumber(), number.isFinite, number.isPositive else { return nil }
        return number.truncated
    }

    private static func scanProviderData(_ scanner: inout JSONScanner) throws(JSONScanError) -> ProviderData? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var data = ProviderData()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "skipRun") {
                data.skipRun = try scanner.readBool() == true
            } else if scanner.key(key, is: "isPartialAborted") {
                data.isPartialAborted = try scanner.readBool() == true
            } else if scanner.key(key, is: "error") {
                data.hasError = scanner.nextIsObject
                try scanner.skipValue()
            } else if scanner.key(key, is: "agent") {
                data.isCompaction = try scanner.readStringMatch(["compact"]) == 0
            } else if scanner.key(key, is: "messageId") {
                data.messageId = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "model") {
                data.model = try scanner.readString()
            } else if scanner.key(key, is: "requestModelId") {
                data.requestModelId = try scanner.readString()
            } else if scanner.key(key, is: "usage") {
                data.usage = try scanAgentsUsage(&scanner)
            } else if scanner.key(key, is: "rawUsage") {
                data.rawUsage = try scanRawUsage(&scanner)
            } else {
                try scanner.skipValue()
            }
        }
        return data
    }

    private static func call(from data: ProviderData) -> WorkBuddyCall {
        var call = WorkBuddyCall(messageId: data.messageId)
        call.modes = ExecutionModeAdapters.routing(data.requestModelId)
        if data.usage != nil || data.rawUsage != nil {
            call.tokens = WorkBuddyTokens.normalize(data.usage, data.rawUsage)
        }
        let model = [data.model, data.requestModelId].lazy.compactMap { $0.map(stripped) }.first { !$0.isEmpty }
        guard let model else { return call }
        if let rest = userModel(model) {
            call.model = rest.isEmpty ? nil : rest
            call.provider = "custom"
        } else {
            call.model = model
        }
        return call
    }

    /// The id after a `custom:` or `custom-local:` prefix (any case), trimmed; nil without such a prefix.
    private static func userModel(_ model: String) -> String? {
        let scalars = model.unicodeScalars
        for prefix in userPrefixes {
            var index = scalars.startIndex
            var matches = true
            for expected in prefix.unicodeScalars {
                guard index < scalars.endIndex else { matches = false; break }
                var value = scalars[index].value
                if (0x41...0x5A).contains(value) { value += 0x20 }
                guard value == expected.value else { matches = false; break }
                index = scalars.index(after: index)
            }
            if matches { return stripped(String(scalars[index...])) }
        }
        return nil
    }

    // MARK: - Usage

    private static func scanAgentsUsage(_ scanner: inout JSONScanner) throws(JSONScanError) -> WorkBuddyAgentsUsage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var usage = WorkBuddyAgentsUsage()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "inputTokens") {
                usage.inputTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "outputTokens") {
                usage.outputTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "inputTokensDetails") {
                usage.cachedTokens = try scanDetails(&scanner, field: "cached_tokens")
            } else if scanner.key(key, is: "outputTokensDetails") {
                usage.reasoningTokens = try scanDetails(&scanner, field: "reasoning_tokens")
            } else {
                try scanner.skipValue()
            }
        }
        return usage
    }

    /// Σ `field` over a list of detail objects (one object counts as a list of one); other entries count 0.
    private static func scanDetails(_ scanner: inout JSONScanner, field: StaticString) throws(JSONScanError) -> Int {
        guard try scanner.beginArrayIfPresent() else { return try scanDetail(&scanner, field: field) }
        var sum = 0
        while try scanner.nextElement() {
            sum = WorkBuddyTokens.add(sum, try scanDetail(&scanner, field: field))
        }
        return sum
    }

    private static func scanDetail(_ scanner: inout JSONScanner, field: StaticString) throws(JSONScanError) -> Int {
        guard try scanner.beginObjectIfPresent() else { return 0 }
        var value: JSONNumber?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: field) {
                value = try scanner.readNumber()
            } else {
                try scanner.skipValue()
            }
        }
        return WorkBuddyTokens.count(value)
    }

    private static func scanRawUsage(_ scanner: inout JSONScanner) throws(JSONScanError) -> WorkBuddyRawUsage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var raw = WorkBuddyRawUsage()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "prompt_tokens") {
                raw.promptTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "completion_tokens") {
                raw.completionTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "cache_read_input_tokens") {
                raw.cacheReadInputTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "cache_creation_input_tokens") {
                raw.cacheCreationInputTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "prompt_cache_hit_tokens") {
                raw.promptCacheHitTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "prompt_cache_write_tokens") {
                raw.promptCacheWriteTokens = try scanner.readNumber()
            } else if scanner.key(key, is: "prompt_tokens_details") {
                raw.detailCachedTokens = try scanDetailNumber(&scanner, field: "cached_tokens")
            } else if scanner.key(key, is: "completion_tokens_details") {
                raw.detailReasoningTokens = try scanDetailNumber(&scanner, field: "reasoning_tokens")
            } else {
                try scanner.skipValue()
            }
        }
        return raw
    }

    /// `field` of a details object; nil when the value is not an object or lacks a number.
    private static func scanDetailNumber(_ scanner: inout JSONScanner, field: StaticString) throws(JSONScanError) -> JSONNumber? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var value: JSONNumber?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: field) {
                value = try scanner.readNumber()
            } else {
                try scanner.skipValue()
            }
        }
        return value
    }

    // MARK: - Text

    /// Python's `str.strip()`.
    static func stripped(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !JSONScanner.isPythonWhitespace($0.value) }) else { return "" }
        let last = scalars.lastIndex(where: { !JSONScanner.isPythonWhitespace($0.value) })!
        return String(scalars[first...last])
    }

    private static func hasVisibleText(_ text: String) -> Bool {
        text.unicodeScalars.contains { !JSONScanner.isPythonWhitespace($0.value) }
    }
}
