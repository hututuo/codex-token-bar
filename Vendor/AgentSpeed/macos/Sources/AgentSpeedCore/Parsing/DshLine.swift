import Foundation

/// The first header of a DeepSeek Harness session (METRICS 4.3).
struct DshHeader: Equatable, Sendable {
    var id: String?
    /// `createdAt`; 0 when it is missing.
    var createdMs: Int64 = 0
    var cwd: String?
    var parentSession: String?
    var origin: String?
    var delegationDepth: Int64 = 0

    var isSubagent: Bool { origin == "subagent" || delegationDepth > 0 || parentSession != nil }
}

struct DshAssistantMessage: Equatable, Sendable {
    var id: String?
    var seq: Int64?
    var model: String?
    /// `source.provider`.
    var provider: String?
    /// Set when `data.usage` is an object.
    var usage: TokenUsage?
    /// `data.message.content` has a block of type `tool-call`.
    var hasToolCall = false
}

enum DshEventKind: Equatable, Sendable {
    case requestHeader(model: String?, provider: String?)
    case stepStart
    case assistantMessage(DshAssistantMessage)
    case turnEnd
    case localDisplayStop
    case other
}

/// One record of a line once `event` and `snapshot` wrappers are unwrapped.
enum DshRecord: Equatable, Sendable {
    case header(DshHeader)
    /// An event with a numeric `time`; events without one are ignored and never recorded.
    case event(timeMs: Int64, kind: DshEventKind)
}

struct DshLine: Equatable, Sendable {
    /// In stream order: a snapshot yields its header, then each of its records.
    var records: [DshRecord]
}

/// Decodes the fields of a DeepSeek Harness session line that METRICS 4.3 needs. Conversation text is never captured.
enum DshLineExtractor {
    private static let types: [StaticString] = [
        "event", "snapshot", "session", "request/header", "step/start", "assistant/message", "turn/end", "request/error", "turn/error", "turn/aborted",
    ]

    /// Every member any object kind may need; which ones apply is decided once `type` is known.
    private struct Members {
        var type: Int?
        var time: Int64?
        var seq: Int64?
        var event: [DshRecord]?
        var header: DshHeader?
        var records: [DshRecord] = []
        var own = DshHeader()
        var requestModel: String?
        var requestProvider: String?
        var message = DshAssistantMessage()
    }

    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<DshLine> {
        var scanner = JSONScanner(bytes)
        if scanner.isBlank { return .blank }
        do {
            var records: [DshRecord] = []
            try scanner.beginObject()
            try scanObject(&scanner, into: &records)
            try scanner.finish()
            return .line(DshLine(records: records))
        } catch {
            return .malformed
        }
    }

    /// Scans the members of an entered object and appends its records. Recursion is bounded by the scanner's depth limit.
    private static func scanObject(_ scanner: inout JSONScanner, into records: inout [DshRecord]) throws(JSONScanError) {
        var members = Members()
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "type") {
                members.type = try scanner.readStringMatch(types)
            } else if scanner.key(key, is: "time") {
                members.time = try scanner.readInteger()
            } else if scanner.key(key, is: "seq") {
                members.seq = try scanner.readInteger()
            } else if scanner.key(key, is: "event") {
                members.event = nil
                if try scanner.beginObjectIfPresent() {
                    var inner: [DshRecord] = []
                    try scanObject(&scanner, into: &inner)
                    members.event = inner
                }
            } else if scanner.key(key, is: "header") {
                members.header = nil
                if try scanner.beginObjectIfPresent() {
                    var header = DshHeader()
                    try scanHeaderMembers(&scanner, into: &header)
                    members.header = header
                }
            } else if scanner.key(key, is: "records") {
                members.records = try scanRecords(&scanner)
            } else if scanner.key(key, is: "data") {
                try scanData(&scanner, into: &members)
            } else if try !scanHeaderMember(key, &scanner, into: &members.own) {
                try scanner.skipValue()
            }
        }

        switch members.type {
        case 0:
            if let inner = members.event {
                records.append(contentsOf: inner)
                return
            }
        case 1:
            if let header = members.header { records.append(.header(header)) }
            records.append(contentsOf: members.records)
            return
        case 2:
            records.append(.header(members.own))
            return
        default:
            break
        }
        guard let time = members.time else { return }
        let kind: DshEventKind
        switch members.type {
        case 3: kind = .requestHeader(model: members.requestModel, provider: members.requestProvider)
        case 4: kind = .stepStart
        case 5:
            var message = members.message
            message.seq = members.seq
            kind = .assistantMessage(message)
        case 6: kind = .turnEnd
        case 7, 8, 9: kind = .localDisplayStop
        default: kind = .other
        }
        records.append(.event(timeMs: time, kind: kind))
    }

    private static func scanRecords(_ scanner: inout JSONScanner) throws(JSONScanError) -> [DshRecord] {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return []
        }
        var records: [DshRecord] = []
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            try scanObject(&scanner, into: &records)
        }
        return records
    }

    private static func scanHeaderMembers(_ scanner: inout JSONScanner, into header: inout DshHeader) throws(JSONScanError) {
        while let key = try scanner.nextMember() {
            if try !scanHeaderMember(key, &scanner, into: &header) {
                try scanner.skipValue()
            }
        }
    }

    /// Reads one header member; returns false (consuming nothing) for any other key.
    private static func scanHeaderMember(
        _ key: JSONKey,
        _ scanner: inout JSONScanner,
        into header: inout DshHeader
    ) throws(JSONScanError) -> Bool {
        if scanner.key(key, is: "id") {
            header.id = try scanner.readNonEmptyString()
        } else if scanner.key(key, is: "createdAt") {
            header.createdMs = try scanner.readInteger() ?? 0
        } else if scanner.key(key, is: "cwd") {
            header.cwd = try scanner.readNonEmptyString()
        } else if scanner.key(key, is: "parentSession") {
            header.parentSession = try scanner.readNonEmptyString()
        } else if scanner.key(key, is: "origin") {
            header.origin = try scanner.readString()
        } else if scanner.key(key, is: "delegationDepth") {
            header.delegationDepth = try scanner.readInteger() ?? 0
        } else {
            return false
        }
        return true
    }

    private static func scanData(_ scanner: inout JSONScanner, into members: inout Members) throws(JSONScanError) {
        members.requestModel = nil
        members.requestProvider = nil
        members.message = DshAssistantMessage()
        guard try scanner.beginObjectIfPresent() else { return }
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "header") {
                (members.requestModel, members.requestProvider) = try scanRequestConfig(&scanner)
            } else if scanner.key(key, is: "message") {
                let usage = members.message.usage
                members.message = try scanMessage(&scanner)
                members.message.usage = usage
            } else if scanner.key(key, is: "usage") {
                members.message.usage = try scanUsage(&scanner)
            } else {
                try scanner.skipValue()
            }
        }
    }

    /// `data.header.config.model` and `.provider`.
    private static func scanRequestConfig(_ scanner: inout JSONScanner) throws(JSONScanError) -> (String?, String?) {
        guard try scanner.beginObjectIfPresent() else { return (nil, nil) }
        var model: String?
        var provider: String?
        while let key = try scanner.nextMember() {
            guard scanner.key(key, is: "config") else {
                try scanner.skipValue()
                continue
            }
            model = nil
            provider = nil
            guard try scanner.beginObjectIfPresent() else { continue }
            while let inner = try scanner.nextMember() {
                if scanner.key(inner, is: "model") {
                    model = try scanner.readNonEmptyString()
                } else if scanner.key(inner, is: "provider") {
                    provider = try scanner.readNonEmptyString()
                } else {
                    try scanner.skipValue()
                }
            }
        }
        return (model, provider)
    }

    /// `data.message`: its id, `source.model` and whether any content block is a `tool-call`.
    private static func scanMessage(_ scanner: inout JSONScanner) throws(JSONScanError) -> DshAssistantMessage {
        var message = DshAssistantMessage()
        guard try scanner.beginObjectIfPresent() else { return message }
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "id") {
                message.id = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "source") {
                (message.model, message.provider) = try scanSource(&scanner)
            } else if scanner.key(key, is: "content") {
                message.hasToolCall = try scanHasToolCall(&scanner)
            } else {
                try scanner.skipValue()
            }
        }
        return message
    }

    private static func scanSource(_ scanner: inout JSONScanner) throws(JSONScanError) -> (String?, String?) {
        guard try scanner.beginObjectIfPresent() else { return (nil, nil) }
        var model: String?
        var provider: String?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "model") {
                model = try scanner.readNonEmptyString()
            } else if scanner.key(key, is: "provider") {
                provider = try scanner.readNonEmptyString()
            } else {
                try scanner.skipValue()
            }
        }
        return (model, provider)
    }

    private static func scanHasToolCall(_ scanner: inout JSONScanner) throws(JSONScanError) -> Bool {
        guard try scanner.beginArrayIfPresent() else {
            try scanner.skipValue()
            return false
        }
        var found = false
        while try scanner.nextElement() {
            guard try scanner.beginObjectIfPresent() else { continue }
            var isToolCall = false
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "type") {
                    isToolCall = try scanner.readStringMatch(["tool-call"]) == 0
                } else {
                    try scanner.skipValue()
                }
            }
            if isToolCall { found = true }
        }
        return found
    }

    /// `data.usage`, normalized: input includes cache reads and writes; dsh reports no separate reasoning count.
    private static func scanUsage(_ scanner: inout JSONScanner) throws(JSONScanError) -> TokenUsage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "inputTokens") {
                input = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "outputTokens") {
                output = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cacheReadTokens") {
                cacheRead = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cacheWriteTokens") {
                cacheWrite = TokenCount.clamp(try scanner.readInteger())
            } else {
                try scanner.skipValue()
            }
        }
        return TokenUsage(
            input: TokenCount.sum(input, cacheRead, cacheWrite),
            cachedInput: cacheRead,
            cacheWriteInput: cacheWrite,
            output: output,
            reasoning: 0
        )
    }
}
