import Foundation

/// One `session_v2` row (METRICS 4.5).
struct OpencodeSessionInfo: Equatable, Sendable {
    var id: String
    var parentId: String?
    var directory: String?
    var createdMs: Int64
    var updatedMs: Int64
}

/// One `session_message` row reduced to the fields METRICS 4.5 needs. Conversation content is never captured.
struct OpencodeRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case assistant
        case compaction
        case idle
        case other
    }

    var id: String
    var seq: Int64
    var kind: Kind
    var timeCreated: Int64
    var timeUpdated: Int64
    /// Nil when `data` is not a JSON object (a malformed row).
    var data: OpencodeMessageData?

    init(id: String, seq: Int64, kind: Kind, timeCreated: Int64, timeUpdated: Int64, data: OpencodeMessageData?) {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.timeCreated = timeCreated
        self.timeUpdated = timeUpdated
        self.data = data
    }

    static func kind(of type: String?) -> Kind {
        switch type {
        case "assistant": .assistant
        case "compaction": .compaction
        case "idle": .idle
        default: .other
        }
    }
}

/// The parts of `session_message.data` that matter.
struct OpencodeMessageData: Equatable, Sendable {
    var created: Int64?
    /// Absent while the request is in flight.
    var streamed: Int64?
    var completed: Int64?
    var model: String?
    /// `model.providerID` (METRICS 3.2).
    var provider: String?
    var modes: ExecutionModes = .empty
    var finishedWithToolCalls = false
    /// Set when `data.tokens` is an object.
    var tokens: TokenUsage?
}

enum OpencodeDataExtractor {
    /// Decodes a `data` document. Nil when it is not a JSON object.
    static func extract(_ bytes: UnsafeRawBufferPointer) -> OpencodeMessageData? {
        var scanner = JSONScanner(bytes)
        do {
            var data = OpencodeMessageData()
            var tier: String?
            try scanner.beginObject()
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "time") {
                    try scanTime(&scanner, into: &data)
                } else if scanner.key(key, is: "model") {
                    (data.model, data.provider) = try scanModel(&scanner)
                } else if scanner.key(key, is: "finish") {
                    data.finishedWithToolCalls = try scanner.readStringMatch(["tool-calls"]) == 0
                } else if scanner.key(key, is: "native") {
                    guard try scanner.beginObjectIfPresent() else { continue }
                    while let nativeKey = try scanner.nextMember() {
                        if scanner.key(nativeKey, is: "serviceTier") { tier = try scanner.readString() }
                        else { try scanner.skipValue() }
                    }
                } else if scanner.key(key, is: "tokens") {
                    data.tokens = try scanTokens(&scanner)
                } else {
                    try scanner.skipValue()
                }
            }
            try scanner.finish()
            if ["openai", "azure"].contains(data.provider ?? "") {
                data.modes = ExecutionModeAdapters.openAI(tier, evidence: .served, scope: .response)
            }
            return data
        } catch {
            return nil
        }
    }

    private static func scanTime(_ scanner: inout JSONScanner, into data: inout OpencodeMessageData) throws(JSONScanError) {
        data.created = nil
        data.streamed = nil
        data.completed = nil
        guard try scanner.beginObjectIfPresent() else { return }
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "created") {
                data.created = try scanner.readInteger()
            } else if scanner.key(key, is: "streamed") {
                data.streamed = try scanner.readInteger()
            } else if scanner.key(key, is: "completed") {
                data.completed = try scanner.readInteger()
            } else {
                try scanner.skipValue()
            }
        }
    }

    private static func scanModel(_ scanner: inout JSONScanner) throws(JSONScanError) -> (String?, String?) {
        guard try scanner.beginObjectIfPresent() else { return (nil, nil) }
        var model: String?
        var provider: String?
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "id") {
                model = try scanner.readString()
            } else if scanner.key(key, is: "providerID") {
                provider = try scanner.readNonEmptyString()
            } else {
                try scanner.skipValue()
            }
        }
        return (model, provider)
    }

    /// OpenCode reports reasoning separately from output (METRICS 4.5).
    private static func scanTokens(_ scanner: inout JSONScanner) throws(JSONScanError) -> TokenUsage? {
        guard try scanner.beginObjectIfPresent() else { return nil }
        var input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0
        while let key = try scanner.nextMember() {
            if scanner.key(key, is: "input") {
                input = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "output") {
                output = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "reasoning") {
                reasoning = TokenCount.clamp(try scanner.readInteger())
            } else if scanner.key(key, is: "cache") {
                cacheRead = 0
                cacheWrite = 0
                guard try scanner.beginObjectIfPresent() else { continue }
                while let inner = try scanner.nextMember() {
                    if scanner.key(inner, is: "read") {
                        cacheRead = TokenCount.clamp(try scanner.readInteger())
                    } else if scanner.key(inner, is: "write") {
                        cacheWrite = TokenCount.clamp(try scanner.readInteger())
                    } else {
                        try scanner.skipValue()
                    }
                }
            } else {
                try scanner.skipValue()
            }
        }
        return TokenUsage(
            input: TokenCount.sum(input, cacheRead, cacheWrite),
            cachedInput: cacheRead,
            cacheWriteInput: cacheWrite,
            output: TokenCount.sum(output, reasoning),
            reasoning: reasoning
        )
    }
}
