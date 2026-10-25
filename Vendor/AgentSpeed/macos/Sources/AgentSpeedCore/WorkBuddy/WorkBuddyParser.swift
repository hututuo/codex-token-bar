import Foundation

/// Per-file WorkBuddy / WorkBuddy AI state machine (METRICS 4.9). Both editions write the same format.
struct WorkBuddyParser: Sendable {
    /// A call's usage repeats within its run (last output item, then `model-usage`), so recent keys are enough.
    static let mergeMemory = 1024
    /// The response key of a call without `messageId`.
    static let fallbackKeyPrefix = "workbuddy:"

    let agentId: String
    let fileID: FileID
    private(set) var state: AgentState

    private var pendingStartMs: Int64?
    /// Tool call id → the key of the call that made it.
    private var openCalls: [String: String] = [:]
    private var responses: [String: ResponseRecord] = [:]
    private var responseOrder: [String] = []

    /// `root` is the `projects` folder the file was found under.
    init(source: SourceKind, agentId: String, fileID: FileID, root: String?) {
        self.agentId = agentId
        self.fileID = fileID
        state = AgentState(source: source, isSubagent: Self.isSubagent(path: agentId, root: root))
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(_ extraction: LineExtraction<WorkBuddyLine>, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch extraction {
        case .blank:
            return
        case .malformed:
            state.malformedLines += 1
        case .line(let line):
            consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: WorkBuddyLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let timestamp = line.timestampMs else { return }
        state.noteLine(at: timestamp)
        if let cwd = line.cwd {
            state.cwdPath = cwd
            if let name = Self.basename(cwd) { state.project = name }
        }
        switch line.item {
        case .userMessage:
            guard !line.skipRun else { return }
            openCalls.removeAll()
            pendingStartMs = timestamp
            state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
        case .functionCallResult:
            if let callId = line.callId { openCalls[callId] = nil }
            if line.skipRun {
                // A rejected or cancelled tool: no request follows.
                if openCalls.isEmpty { endTurn(at: timestamp) }
            } else {
                pendingStartMs = timestamp
                if openCalls.isEmpty { state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp) }
            }
        case .assistantMessage where line.skipRun:
            // A notice the CLI wrote; only an interruption or an error ends the turn.
            if line.isIncomplete || line.hasError { endTurn(at: timestamp) }
        case .assistantMessage, .functionCall, .reasoning, .modelUsage:
            guard !line.isPartialAborted else { return }
            consumeOutput(line, at: timestamp, deduper: &deduper, emit: emit)
        case .other:
            break
        }
    }

    private mutating func consumeOutput(_ line: WorkBuddyLine, at timestamp: Int64, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let key = line.call.messageId ?? line.id.map({ Self.fallbackKeyPrefix + $0 }),
              !deduper.isOwnedByOtherFile(key, for: fileID) else { return }
        if let tokens = line.call.tokens, tokens.input > 0 || tokens.output > 0 {
            record(key: key, tokens: tokens, call: line.call, at: timestamp, deduper: &deduper, emit: emit)
        }
        if line.item == .modelUsage {
            // Written when the run ends.
            endTurn(at: timestamp)
            return
        }
        if openCalls.contains(where: { $0.value != key }) {
            openCalls = openCalls.filter { $0.value == key }
        }
        switch line.item {
        case .functionCall:
            if let callId = line.callId { openCalls[callId] = key }
            state.setPhase(.tools, at: timestamp)
        case .assistantMessage where openCalls.isEmpty:
            if line.isCompaction {
                // The request it made room for follows.
                pendingStartMs = timestamp
                state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
            } else {
                state.setPhase(.idle, at: timestamp)
            }
        default:
            break
        }
    }

    /// Creates the response of a call, or merges a later line with its usage into it (METRICS 4.4).
    private mutating func record(
        key: String,
        tokens: TokenUsage,
        call: WorkBuddyCall,
        at timestamp: Int64,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        let claim = deduper.claim(key, for: fileID)
        let record: ResponseRecord
        let isMerge = responses[key] != nil
        if var existing = responses[key] {
            existing.endMs = max(existing.endMs, timestamp)
            existing.usage = existing.usage.merged(with: tokens)
            existing.modes = existing.modes.merging(call.modes)
            if let model = call.model { existing.model = model }
            if let provider = call.provider { existing.provider = provider }
            record = existing
        } else {
            record = ResponseRecord(key: key, source: state.source, agentId: agentId, model: call.model,
                                    startMs: pendingStartMs, endMs: timestamp, usage: tokens, isFinal: true,
                                    provider: call.provider, modes: call.modes)
            pendingStartMs = nil
            remember(key)
        }
        responses[key] = record
        state.modes = record.modes
        if let model = record.model { state.model = model }
        emit(ResponseUpsert(record: record, isCompletion: claim == .new && !isMerge))
    }

    private mutating func endTurn(at timestamp: Int64) {
        state.setPhase(.idle, at: timestamp)
        pendingStartMs = nil
        openCalls.removeAll()
    }

    private mutating func remember(_ key: String) {
        responseOrder.append(key)
        guard responseOrder.count > Self.mergeMemory * 2 else { return }
        let evicted = responseOrder.prefix(responseOrder.count - Self.mergeMemory)
        for old in evicted { responses[old] = nil }
        responseOrder.removeFirst(evicted.count)
    }

    // MARK: - Paths

    /// The path relative to `root` (as `os.path.relpath` gives it, split on `/` and `\`) is
    /// `<slug>/<dir>/subagents/<file>`: a `subagents` folder above the root does not count.
    static func isSubagent(path: String, root: String?) -> Bool {
        let components = relativeComponents(path: path, root: root)
        return components.count == 4 && components[2].elementsEqual("subagents".utf8)
    }

    private static func relativeComponents(path: String, root: String?) -> [Substring.UTF8View] {
        let slash = UInt8(ascii: "/")
        let pathParts = path.utf8.split(separator: slash)
        var relative: [Substring.UTF8View]
        if let root, !root.isEmpty {
            let rootParts = root.utf8.split(separator: slash)
            var common = 0
            while common < rootParts.count, common < pathParts.count, rootParts[common].elementsEqual(pathParts[common]) {
                common += 1
            }
            relative = Array(repeating: "..".utf8[...], count: rootParts.count - common) + pathParts[common...]
        } else {
            relative = pathParts
        }
        return relative.flatMap { $0.split(separator: UInt8(ascii: "\\")) }
    }

    /// The last component of `cwd`, split on `/` and `\`.
    private static func basename(_ path: String) -> String? {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }
}
