import Foundation

enum ClaudeLineType: Sendable {
    case assistant
    case user
    case apiRequest
    case other
}

enum ClaudeStopReason: Equatable, Sendable {
    /// `stop_reason` is null or missing.
    case none
    case pauseTurn
    case toolUse
    case other
}

struct ClaudeLine: Equatable, Sendable {
    var timestampMs: Int64?
    var type: ClaudeLineType = .other
    /// Source implied by `entrypoint`, nil when the line has none.
    var entrypointSource: SourceKind?
    var cwd: String?
    var isSidechain = false
    var displayTitle: String?
    var displayTitlePriority = Int.max
    var userTextTitleCandidate: String?
    var messageId: String?
    var requestId: String?
    var uuid: String?
    var model: String?
    var stopReason: ClaudeStopReason = .none
    var usage: TokenUsage = .zero
    /// `message.usage.speed == "fast"` (METRICS 3.2).
    var fast = false
    var modes: ExecutionModes = .empty
    /// A user line whose content starts with `[Request interrupted by user`.
    var isInterrupt = false
    /// Upstream b89d983: StructuredOutput/SubagentHandback can finish a Desktop run.
    var toolEndsTurn = false
    /// `message.content` contains a block of type `tool_use`.
    var hasToolUse = false
    var localDisplayStop = false
}

/// Decodes the fields needed by METRICS 4.1 plus a bounded local-only display title. Full conversation text is not retained.
enum ClaudeLineExtractor {
    private static let lineTypes: [StaticString] = ["assistant", "user", "api-request"]
    private static let stopReasons: [StaticString] = ["pause_turn", "tool_use"]
    private static let interruptPrefix: StaticString = "[Request interrupted by user"
    private static let displayTitleSourceByteLimit = 16 * 1024

    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<ClaudeLine> {
        var scanner = JSONScanner(bytes)
        if scanner.isBlank { return .blank }
        do {
            var line = ClaudeLine()
            try scanner.beginObject()
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "type") {
                    switch try scanner.readStringMatch(lineTypes) {
                    case 0: line.type = .assistant
                    case 1: line.type = .user
                    case 2: line.type = .apiRequest
                    default: line.type = .other
                    }
                } else if scanner.key(key, is: "isApiErrorMessage") {
                    line.localDisplayStop = (try scanner.readBool() ?? false) || line.localDisplayStop
                } else if scanner.key(key, is: "subtype") {
                    let subtype = try scanner.readNonEmptyString()
                    line.localDisplayStop = ["api_error", "stream_error"].contains(subtype ?? "") || line.localDisplayStop
                } else if scanner.key(key, is: "timestamp") {
                    line.timestampMs = try scanner.readTimestamp()
                } else if scanner.key(key, is: "entrypoint") {
                    switch try scanner.readStringHasPrefix("claude-desktop") {
                    case true?: line.entrypointSource = .claudeDesktop
                    case false?: line.entrypointSource = .claudeCode
                    case nil: line.entrypointSource = nil
                    }
                } else if scanner.key(key, is: "cwd") {
                    line.cwd = try scanner.readNonEmptyString()
                } else if scanner.key(key, is: "isSidechain") {
                    line.isSidechain = try scanner.readBool() ?? false
                } else if scanner.key(key, is: "agentName") {
                    setDisplayTitle(try scanner.readBoundedString(maxBytes: displayTitleSourceByteLimit), priority: 0, into: &line)
                } else if scanner.key(key, is: "title") {
                    setDisplayTitle(try scanner.readBoundedString(maxBytes: displayTitleSourceByteLimit), priority: 1, into: &line)
                } else if scanner.key(key, is: "customTitle") {
                    setDisplayTitle(try scanner.readBoundedString(maxBytes: displayTitleSourceByteLimit), priority: 1, into: &line)
                } else if scanner.key(key, is: "summary") {
                    setDisplayTitle(try scanner.readBoundedString(maxBytes: displayTitleSourceByteLimit), priority: 2, into: &line)
                } else if scanner.key(key, is: "toolEndsTurn") {
                    line.toolEndsTurn = try scanner.readBool() ?? false
                } else if scanner.key(key, is: "requestId") {
                    line.requestId = try scanner.readNonEmptyString()
                } else if scanner.key(key, is: "uuid") {
                    line.uuid = try scanner.readNonEmptyString()
                } else if scanner.key(key, is: "message") {
                    try scanMessage(&scanner, into: &line)
                } else {
                    try scanner.skipValue()
                }
            }
            try scanner.finish()
            if line.type != .assistant {
                line.messageId = nil
                line.requestId = nil
                line.uuid = nil
                line.model = nil
            }
            if line.type != .user { line.isInterrupt = false; line.toolEndsTurn = false }
            if line.type != .assistant { line.hasToolUse = false }
            if line.type != .user { line.userTextTitleCandidate = nil }
            return .line(line)
        } catch {
            return .malformed
        }
    }

    private static func scanMessage(_ scanner: inout JSONScanner, into line: inout ClaudeLine) throws(JSONScanError) {
        guard try scanner.beginObjectIfPresent() else { return }
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "id") {
                line.messageId = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "model") {
                line.model = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "stop_reason") {
                if try scanner.readNull() {
                    line.stopReason = .none
                } else {
                    switch try scanner.readStringMatch(stopReasons) {
                    case 0: line.stopReason = .pauseTurn
                    case 1: line.stopReason = .toolUse
                    default: line.stopReason = .other
                    }
                }
            } else if scanner.key(key, is: "usage") {
                (line.usage, line.fast, line.modes) = try scanUsage(&scanner)
            } else if scanner.key(key, is: "content") {
                (line.isInterrupt, line.hasToolUse, line.userTextTitleCandidate) = try scanContent(
                    &scanner,
                    captureUserText: line.type != .assistant
                )
            } else {
                try scanner.skipValue()
            }
        }
    }

    private static func scanUsage(_ scanner: inout JSONScanner) throws(JSONScanError) -> (TokenUsage, fast: Bool, modes: ExecutionModes) {
        guard try scanner.beginObjectIfPresent() else { return (.zero, false, .empty) }
        var input = 0
        var cacheCreation = 0
        var cacheCreation1h = 0
        var cacheRead = 0
        var output = 0
        var thinking = 0
        var fast = false
        var speed: String?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "input_tokens") {
                input = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cache_creation_input_tokens") {
                cacheCreation = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cache_read_input_tokens") {
                cacheRead = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "output_tokens") {
                output = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "output_tokens_details") {
                thinking = try scanNestedCount(&scanner, "thinking_tokens")
            } else if scanner.key(key, is: "cache_creation") {
                cacheCreation1h = try scanNestedCount(&scanner, "ephemeral_1h_input_tokens")
            } else if scanner.key(key, is: "speed") {
                speed = try scanner.readString()
                fast = speed == "fast"
            } else {
                try scanner.skipValue()
            }
        }
        let usage = TokenUsage(
            input: TokenCount.sum(input, cacheCreation, cacheRead),
            cachedInput: cacheRead,
            cacheWriteInput: cacheCreation,
            cacheWrite1hInput: min(cacheCreation1h, cacheCreation),
            output: output,
            reasoning: thinking
        )
        return (usage, fast, ExecutionModeAdapters.claude(speed))
    }

    /// One integer member of a nested object (`output_tokens_details.thinking_tokens`,
    /// `cache_creation.ephemeral_1h_input_tokens`); 0 when absent.
    private static func scanNestedCount(_ scanner: inout JSONScanner, _ name: StaticString) throws(JSONScanError) -> Int {
        guard try scanner.beginObjectIfPresent() else { return 0 }
        var count = 0
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: name) {
                count = TokenCount.clamp(try scanner.readInteger())
            } else {
                try scanner.skipValue()
            }
        }
        return count
    }

    /// Whether string content or any top-level `text` block starts with the interrupt marker, and whether any
    /// top-level block is a `tool_use`.
    private static func scanContent(
        _ scanner: inout JSONScanner,
        captureUserText: Bool
    ) throws(JSONScanError) -> (interrupt: Bool, toolUse: Bool, userTextTitle: String?) {
        if scanner.nextIsString {
            let value = try scanner.readStringPrefixAndValue(
                interruptPrefix,
                maxCapturedBytes: captureUserText ? displayTitleSourceByteLimit : 0
            )
            return (
                value.hasPrefix ?? false,
                false,
                captureUserText ? firstMeaningfulDisplayTitle(value.value) : nil
            )
        }
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return (false, false, nil)
        }
        var interrupted = false
        var toolUse = false
        var userTextTitle: String?
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            var blockType: Int?
            var hasPrefix = false
            var text: String?
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "type") {
                    blockType = try scanner.readStringMatch(["text", "tool_use"])
                } else if scanner.key(key, is: "text") {
                    let value = try scanner.readStringPrefixAndValue(
                        interruptPrefix,
                        maxCapturedBytes: captureUserText ? displayTitleSourceByteLimit : 0
                    )
                    text = value.value
                    hasPrefix = value.hasPrefix ?? false
                } else {
                    try scanner.skipValue()
                }
            }
            if blockType == 0 && hasPrefix { interrupted = true }
            if blockType == 1 { toolUse = true }
            if blockType == 0 && userTextTitle == nil {
                userTextTitle = firstMeaningfulDisplayTitle(text)
            }
        }
        return (interrupted, toolUse, userTextTitle)
    }

    private static func setDisplayTitle(_ raw: String?, priority: Int, into line: inout ClaudeLine) {
        guard let title = firstMeaningfulDisplayTitle(raw), priority < line.displayTitlePriority else { return }
        line.displayTitle = title
        line.displayTitlePriority = priority
    }

    private static let systemTags = [
        "system-reminder", "task-notification", "command-message", "command-name", "command-args",
        "local-command-caveat", "local-command-stdout", "local-command-stderr", "available-deferred-tools",
        "user-prompt-submit-hook",
    ]

    private static func firstMeaningfulDisplayTitle(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var skippedTag: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let lineScalars = String.UnicodeScalarView(rawLine.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) ? UnicodeScalar(32)! : scalar
            })
            var line = String(lineScalars).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("[Request interrupted by user") else { continue }

            if let tag = skippedTag {
                let closing = "</\(tag)>"
                guard let range = line.range(of: closing, options: .caseInsensitive) else { continue }
                line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                skippedTag = nil
                if line.isEmpty { continue }
            }

            for tag in systemTags {
                let opening = "<\(tag)>"
                guard line.lowercased().hasPrefix(opening) else { continue }
                let closing = "</\(tag)>"
                if let range = line.range(of: closing, options: .caseInsensitive, range: line.index(line.startIndex, offsetBy: opening.count)..<line.endIndex) {
                    line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    skippedTag = tag
                    line = ""
                }
                break
            }

            if line.isEmpty || (line.hasPrefix("<") && line.hasSuffix(">")) { continue }
            var titleScalars = String.UnicodeScalarView()
            for scalar in line.unicodeScalars.prefix(120) { titleScalars.append(scalar) }
            return String(titleScalars)
        }
        return nil
    }
}
