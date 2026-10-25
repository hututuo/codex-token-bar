import Foundation

/// A tool call attached to a `gemini` message (METRICS 4.6).
struct GeminiToolCall: Equatable, Sendable {
    var id: String
    var timestampMs: Int64?
    /// `name == "complete_task"` with `status == "success"`: a sub-agent finished.
    var completesTask = false
    var isCancelled = false
}

/// One message record. Conversation text is never captured, only whether visible text exists.
struct GeminiMessage: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case gemini
        case error
        /// `info` whose content is exactly `Request cancelled.`
        case cancelled
        case other
    }

    var id: String
    var kind: Kind
    var timestampMs: Int64?
    /// Latest parseable timestamp of the tool calls (with string ids) and thoughts.
    var latestDetailMs: Int64?
    var tokens: TokenUsage?
    var model: String?
    var hasVisibleText = false
    var hasFunctionCall = false
    var toolCalls: [GeminiToolCall] = []
}

/// A `gemini` message inside a `$set.messages` checkpoint that can stand for a response.
struct GeminiCheckpointResponse: Equatable, Sendable {
    var id: String
    var timestampMs: Int64
    var tokens: TokenUsage
    var model: String?
}

struct GeminiCheckpoint: Equatable, Sendable {
    /// FNV-1a hashes of every message id in the checkpoint.
    var idHashes: Set<UInt64> = []
    var responses: [GeminiCheckpointResponse] = []
}

struct GeminiHeader: Equatable, Sendable {
    var sessionId: String
    var isSubagentKind = false
    var startMs: Int64?
    var lastUpdatedMs: Int64?
    /// A legacy object (whole file, or written on one line) carries every message.
    var messages: [GeminiMessage]?
}

struct GeminiMetadata: Equatable, Sendable {
    var lastUpdatedMs: Int64?
    var isSubagentKind = false
    var sessionId: String?
    var checkpoint: GeminiCheckpoint?
    var hasSummary = false
}

/// One classified record of a Gemini CLI session (METRICS 4.6).
enum GeminiLine: Equatable, Sendable {
    case rewind
    case patch(removedIdHashes: Set<UInt64>)
    case message(GeminiMessage)
    case metadata(GeminiMetadata)
    case header(GeminiHeader)
    /// A whole legacy `.json` session file.
    case document(GeminiHeader)
    case ignored
}

/// Decodes Gemini CLI records. Conversation content is skipped (only validated).
enum GeminiLineExtractor {
    private static let messageTypes: [StaticString] = ["user", "gemini", "error", "info"]
    private static let cancelledText: StaticString = "Request cancelled."

    /// One `.jsonl` line.
    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<GeminiLine> {
        var scanner = JSONScanner(bytes)
        if scanner.isBlank { return .blank }
        do {
            try scanner.beginObject()
            let members = try scanTopLevel(&scanner)
            try scanner.finish()
            return .line(members.classified())
        } catch {
            return .malformed
        }
    }

    /// A whole legacy `.json` file: an object with a string `sessionId`, else malformed.
    static func extractDocument(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<GeminiLine> {
        var scanner = JSONScanner(bytes)
        do {
            try scanner.beginObject()
            let members = try scanTopLevel(&scanner)
            try scanner.finish()
            guard let sessionId = members.sessionId else { return .malformed }
            return .line(.document(members.header(sessionId: sessionId)))
        } catch {
            return .malformed
        }
    }

    // MARK: - Top level

    private struct TopLevel {
        var rewind = false
        var patch: Set<UInt64>?
        var message = MessageMembers()
        var metadata: GeminiMetadata?
        var sessionId: String?
        var hasProjectHash = false
        var isSubagentKind = false
        var startMs: Int64?
        var lastUpdatedMs: Int64?
        var messages: [GeminiMessage]?

        func header(sessionId: String) -> GeminiHeader {
            GeminiHeader(sessionId: sessionId, isSubagentKind: isSubagentKind, startMs: startMs,
                         lastUpdatedMs: lastUpdatedMs, messages: messages)
        }

        /// Gemini's own loader order: `$rewindTo`, `$patch`, message, `$set`, header.
        func classified() -> GeminiLine {
            if rewind { return .rewind }
            if let patch { return .patch(removedIdHashes: patch) }
            if let message = message.message() { return .message(message) }
            if let metadata { return .metadata(metadata) }
            if let sessionId, hasProjectHash { return .header(header(sessionId: sessionId)) }
            return .ignored
        }
    }

    private static func scanTopLevel(_ scanner: inout JSONScanner) throws(JSONScanError) -> TopLevel {
        var top = TopLevel()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "$rewindTo") {
                top.rewind = try scanner.readStringIsNonEmpty() != nil
            } else if scanner.key(key, is: "$patch") {
                top.patch = try scanPatch(&scanner)
            } else if scanner.key(key, is: "$set") {
                top.metadata = try scanMetadata(&scanner)
            } else if scanner.key(key, is: "sessionId") {
                top.sessionId = try scanner.readString()
            } else if scanner.key(key, is: "projectHash") {
                top.hasProjectHash = try scanner.readStringIsNonEmpty() != nil
            } else if scanner.key(key, is: "kind") {
                top.isSubagentKind = try scanner.readStringMatch(["subagent"]) == 0
            } else if scanner.key(key, is: "startTime") {
                top.startMs = try scanner.readTimestamp()
            } else if scanner.key(key, is: "lastUpdated") {
                top.lastUpdatedMs = try scanner.readTimestamp()
            } else if scanner.key(key, is: "messages") {
                top.messages = try scanMessages(&scanner)
            } else if try !scanMessageMember(key, &scanner, into: &top.message) {
                try scanner.skipValue()
            }
        }
        return top
    }

    private static func scanPatch(_ scanner: inout JSONScanner) throws(JSONScanError) -> Set<UInt64>? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var removed: Set<UInt64> = []
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "removeIds") {
                removed = []
                guard try scanner.beginArrayIfPresent() else {
                    try scanner.skipValue()
                    continue
                }
                while try scanner.nextElement() {
                    if let id = try scanner.readString() { removed.insert(KeyHash.fnv1a(id)) }
                }
            } else {
                try scanner.skipValue()
            }
        }
        return removed
    }

    private static func scanMetadata(_ scanner: inout JSONScanner) throws(JSONScanError) -> GeminiMetadata? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var metadata = GeminiMetadata()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "lastUpdated") {
                metadata.lastUpdatedMs = try scanner.readTimestamp()
            } else if scanner.key(key, is: "kind") {
                metadata.isSubagentKind = try scanner.readStringMatch(["subagent"]) == 0
            } else if scanner.key(key, is: "sessionId") {
                metadata.sessionId = try scanner.readString()
            } else if scanner.key(key, is: "summary") {
                metadata.hasSummary = try scanner.readStringIsNonEmpty() ?? false
            } else if scanner.key(key, is: "messages") {
                metadata.checkpoint = try scanCheckpoint(&scanner)
            } else {
                try scanner.skipValue()
            }
        }
        return metadata
    }

    // MARK: - Messages

    private struct MessageMembers {
        var id: String?
        var type: Int?
        var timestampMs: Int64?
        var tokens: TokenUsage?
        var model: String?
        var contentIsCancelled = false
        var hasVisibleText = false
        var hasFunctionCall = false
        var toolCalls: [GeminiToolCall] = []
        var latestDetailMs: Int64?

        func message() -> GeminiMessage? {
            guard let id else { return nil }
            let kind: GeminiMessage.Kind = switch type {
            case 0: .user
            case 1: .gemini
            case 2: .error
            case 3: contentIsCancelled ? .cancelled : .other
            default: .other
            }
            return GeminiMessage(
                id: id, kind: kind, timestampMs: timestampMs, latestDetailMs: latestDetailMs, tokens: tokens,
                model: model, hasVisibleText: hasVisibleText, hasFunctionCall: hasFunctionCall, toolCalls: toolCalls
            )
        }
    }

    /// Reads one member of a message object; returns false (consuming nothing) for any other key.
    private static func scanMessageMember(
        _ key: JSONKey,
        _ scanner: inout JSONScanner,
        into message: inout MessageMembers
    ) throws(JSONScanError) -> Bool {
        if scanner.key(key, is: "id") {
            message.id = try scanner.readString()
        } else if scanner.key(key, is: "type") {
            message.type = try scanner.readStringMatch(messageTypes)
        } else if scanner.key(key, is: "timestamp") {
            message.timestampMs = try scanner.readTimestamp()
        } else if scanner.key(key, is: "tokens") {
            message.tokens = try scanTokens(&scanner)
        } else if scanner.key(key, is: "model") {
            message.model = try scanner.readNonEmptyString()
        } else if scanner.key(key, is: "content") {
            try scanContent(&scanner, into: &message)
        } else if scanner.key(key, is: "toolCalls") {
            try scanToolCalls(&scanner, into: &message)
        } else if scanner.key(key, is: "thoughts") {
            try scanThoughts(&scanner, into: &message)
        } else {
            return false
        }
        return true
    }

    private static func scanMessageObject(_ scanner: inout JSONScanner) throws(JSONScanError) -> MessageMembers? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var message = MessageMembers()
        while let key = try scanner.nextMember() {
            if try !scanMessageMember(key, &scanner, into: &message) { try scanner.skipValue() }
        }
        return message
    }

    private static func scanMessages(_ scanner: inout JSONScanner) throws(JSONScanError) -> [GeminiMessage]? {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return nil
        }
        var messages: [GeminiMessage] = []
        while try scanner.nextElement() {
            if let message = try scanMessageObject(&scanner)?.message() { messages.append(message) }
        }
        return messages
    }

    private static func scanCheckpoint(_ scanner: inout JSONScanner) throws(JSONScanError) -> GeminiCheckpoint? {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return nil
        }
        var checkpoint = GeminiCheckpoint()
        while try scanner.nextElement() {
            guard let members = try scanMessageObject(&scanner), let id = members.id else { continue }
            checkpoint.idHashes.insert(KeyHash.fnv1a(id))
            guard members.type == 1, let tokens = members.tokens, let timestamp = members.timestampMs else { continue }
            checkpoint.responses.append(GeminiCheckpointResponse(id: id, timestampMs: timestamp, tokens: tokens, model: members.model))
        }
        return checkpoint
    }

    /// Gemini's `usageMetadata` (METRICS 4.6).
    private static func scanTokens(_ scanner: inout JSONScanner) throws(JSONScanError) -> TokenUsage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var input = 0, output = 0, cached = 0, thoughts = 0, tool = 0
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "input") {
                input = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "output") {
                output = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cached") {
                cached = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "thoughts") {
                thoughts = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "tool") {
                tool = TokenCount.clamp(try scanner.readInteger())
            } else {
                try scanner.skipValue()
            }
        }
        return TokenUsage(input: TokenCount.sum(input, tool), cachedInput: cached, cacheWriteInput: 0,
                          output: TokenCount.sum(output, thoughts), reasoning: thoughts)
    }

    /// Visible text is a string that is not blank, or a non-thought `text` part; `functionCall` parts are calls.
    private static func scanContent(_ scanner: inout JSONScanner, into message: inout MessageMembers) throws(JSONScanError) {
        message.hasVisibleText = false
        message.hasFunctionCall = false
        message.contentIsCancelled = false
        if scanner.nextIsString {
            var probe = scanner
            message.contentIsCancelled = try probe.readStringMatch([cancelledText]) == 0
            message.hasVisibleText = try scanner.readStringHasVisibleText() ?? false
            return
        }
        if scanner.nextIsObject {
            try scanPart(&scanner, into: &message)
            return
        }
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return
        }
        while try scanner.nextElement() {
            if scanner.nextIsString {
                if try scanner.readStringHasVisibleText() == true { message.hasVisibleText = true }
            } else if scanner.nextIsObject {
                try scanPart(&scanner, into: &message)
            } else {
                try scanner.skipValue()
            }
        }
    }

    private static func scanPart(_ scanner: inout JSONScanner, into message: inout MessageMembers) throws(JSONScanError) {
        guard try scanner.beginObjectIfPresent() else { return }
        var visible = false
        var isThought = false
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "functionCall") {
                if scanner.nextIsObject { message.hasFunctionCall = true }
                try scanner.skipValue()
            } else if scanner.key(key, is: "text") {
                visible = try scanner.readStringHasVisibleText() ?? false
            } else if scanner.key(key, is: "thought") {
                isThought = try scanner.readBool() == true
            } else {
                try scanner.skipValue()
            }
        }
        if visible && !isThought { message.hasVisibleText = true }
    }

    private static func scanToolCalls(_ scanner: inout JSONScanner, into message: inout MessageMembers) throws(JSONScanError) {
        message.toolCalls = []
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return
        }
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            var id: String?
            var timestamp: Int64?
            var isCompleteTask = false
            var status: Int?
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "id") {
                    id = try scanner.readString()
                } else if scanner.key(key, is: "name") {
                    isCompleteTask = try scanner.readStringMatch(["complete_task"]) == 0
                } else if scanner.key(key, is: "status") {
                    status = try scanner.readStringMatch(["success", "cancelled"])
                } else if scanner.key(key, is: "timestamp") {
                    timestamp = try scanner.readTimestamp()
                } else {
                    try scanner.skipValue()
                }
            }
            guard let id else { continue }
            if let timestamp { message.latestDetailMs = max(message.latestDetailMs ?? timestamp, timestamp) }
            message.toolCalls.append(GeminiToolCall(
                id: id, timestampMs: timestamp, completesTask: isCompleteTask && status == 0, isCancelled: status == 1))
        }
    }

    private static func scanThoughts(_ scanner: inout JSONScanner, into message: inout MessageMembers) throws(JSONScanError) {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return
        }
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "timestamp"), let timestamp = try scanner.readTimestamp() {
                    message.latestDetailMs = max(message.latestDetailMs ?? timestamp, timestamp)
                } else {
                    try scanner.skipValue()
                }
            }
        }
    }
}
