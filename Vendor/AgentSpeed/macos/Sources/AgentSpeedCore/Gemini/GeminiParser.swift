import Foundation
import os

/// Per-file Gemini CLI state machine (METRICS 4.6). `.jsonl` files are fed line by line; a legacy `.json` file is fed
/// as one document, which resets the state (never the dedupe set) and replays every message.
struct GeminiParser: Sendable {
    let agentId: String
    let fileID: FileID
    /// A legacy whole-document `.json` session.
    let isDocument: Bool
    private(set) var state: AgentState

    private let initialState: AgentState
    /// The sub-agent folder name (`chats/<dir>/<file>`), matched against sanitized session ids (METRICS 6.7).
    private let parentFolder: String?
    private var sessionId: String?
    private var startMs: Int64?
    private var pendingStartMs: Int64?
    /// FNV-1a hash of the id of the record that set `pendingStartMs`.
    private var markerHash: UInt64?
    private var seenToolCalls: Set<String> = []
    private var responses: [String: ResponseRecord] = [:]

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
        isDocument = agentId.hasSuffix(".json")
        let components = agentId.split(separator: "/", omittingEmptySubsequences: true)
        let nested = components.count >= 3 && components[components.count - 3] == "chats"
        parentFolder = nested ? String(components[components.count - 2]) : nil
        var state = AgentState(source: .gemini, isSubagent: nested)
        let project = GeminiProjects.shared.project(forSessionAt: agentId)
        state.project = project?.name
        state.cwdPath = project?.root
        state.thread = SessionThread(id: nil, parentId: parentFolder, createdMs: 0)
        self.state = state
        initialState = state
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(_ extraction: LineExtraction<GeminiLine>, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch extraction {
        case .blank:
            return
        case .malformed:
            // A legacy document caught mid-write keeps its previous state.
            state.malformedLines += 1
        case .line(let line):
            consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: GeminiLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch line {
        case .rewind:
            idle()
        case .patch(let removed):
            if state.phase == .generating, let markerHash, removed.contains(markerHash) { idle() }
        case .message(let message):
            consume(message, deduper: &deduper, emit: emit)
        case .metadata(let metadata):
            if let updated = metadata.lastUpdatedMs { state.noteLine(at: updated) }
            if metadata.isSubagentKind { state.isSubagent = true }
            if let id = metadata.sessionId { setSession(id) }
            if let checkpoint = metadata.checkpoint { apply(checkpoint, deduper: &deduper, emit: emit) }
            if metadata.hasSummary { idle() }
        case .header(let header):
            consume(header, deduper: &deduper, emit: emit)
        case .document(let header):
            reset()
            consume(header, deduper: &deduper, emit: emit)
        case .ignored:
            break
        }
    }

    private mutating func consume(_ header: GeminiHeader, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        if header.isSubagentKind { state.isSubagent = true }
        if startMs == nil { startMs = header.startMs }
        setSession(header.sessionId)
        if let start = header.startMs { state.noteLine(at: start) }
        if let updated = header.lastUpdatedMs { state.noteLine(at: updated) }
        for message in header.messages ?? [] { consume(message, deduper: &deduper, emit: emit) }
    }

    private mutating func consume(_ message: GeminiMessage, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let timestamp = message.timestampMs else { return }
        state.noteLine(at: timestamp)
        if let detail = message.latestDetailMs { state.noteLine(at: detail) }
        switch message.kind {
        case .user:
            generating(from: timestamp, marker: message.id)
            return
        case .error, .cancelled:
            idle()
            return
        case .other:
            return
        case .gemini:
            break
        }
        let key = message.id
        guard !deduper.isOwnedByOtherFile(key, for: fileID) else { return }
        if let tokens = message.tokens {
            if let existing = responses[key] {
                update(existing, endMs: timestamp, tokens: tokens, model: message.model, emit: emit)
            } else {
                // A message created when its tools finished (≤ v0.31) has no known stream end.
                let firstCall = message.toolCalls.compactMap(\.timestampMs).min()
                let start = firstCall.map { timestamp >= $0 } == true ? nil : pendingStartMs
                record(key: key, startMs: start, endMs: timestamp, tokens: tokens, model: message.model, deduper: &deduper, emit: emit)
                let visibleAnswer = message.hasVisibleText && !message.hasFunctionCall
                state.setPhase(visibleAnswer ? .idle : .tools, at: timestamp)
                pendingStartMs = nil
                markerHash = nil
            }
        }
        let fresh = message.toolCalls.filter { !seenToolCalls.contains($0.id) }
        for call in fresh { seenToolCalls.insert(call.id) }
        guard !fresh.isEmpty else { return }
        if fresh.contains(where: \.completesTask) || fresh.allSatisfy(\.isCancelled) {
            idle()
        } else {
            generating(from: fresh.compactMap(\.timestampMs).max() ?? timestamp, marker: key)
        }
    }

    /// `$set.messages` (v0.44 – v0.63): every message repeated; an in-flight request missing from it was rolled back.
    private mutating func apply(_ checkpoint: GeminiCheckpoint, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        for response in checkpoint.responses where !deduper.isOwnedByOtherFile(response.id, for: fileID) {
            if let existing = responses[response.id] {
                update(existing, endMs: response.timestampMs, tokens: response.tokens, model: response.model, emit: emit)
            } else {
                record(key: response.id, startMs: nil, endMs: response.timestampMs, tokens: response.tokens,
                       model: response.model, deduper: &deduper, emit: emit)
            }
        }
        if state.phase == .generating, !(markerHash.map(checkpoint.idHashes.contains) ?? false) { idle() }
    }

    private mutating func record(
        key: String,
        startMs: Int64?,
        endMs: Int64,
        tokens: TokenUsage,
        model: String?,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        let claim = deduper.claim(key, for: fileID)
        let record = ResponseRecord(key: key, source: .gemini, agentId: agentId, model: model, startMs: startMs,
                                    endMs: endMs, usage: tokens, isFinal: true)
        responses[key] = record
        if let model { state.model = model }
        // After a document reset the key is already ours: an update of the earlier emission (METRICS 4.4).
        emit(ResponseUpsert(record: record, isCompletion: claim == .new))
    }

    private mutating func update(_ existing: ResponseRecord, endMs: Int64, tokens: TokenUsage, model: String?, emit: (ResponseUpsert) -> Void) {
        var record = existing
        record.usage = tokens
        record.endMs = max(record.endMs, endMs)
        if let model { record.model = model }
        if let model = record.model { state.model = model }
        guard record != existing else { return }
        responses[record.key] = record
        emit(ResponseUpsert(record: record, isCompletion: false))
    }

    private mutating func idle() {
        state.setPhase(.idle, at: state.lastLineMs ?? 0)
        pendingStartMs = nil
        markerHash = nil
    }

    private mutating func generating(from start: Int64, marker: String) {
        pendingStartMs = start
        markerHash = KeyHash.fnv1a(marker)
        state.setPhase(.generating, at: start, inFlightStartMs: start)
    }

    private mutating func setSession(_ id: String) {
        sessionId = id
        state.thread = SessionThread(id: id, parentId: parentFolder, createdMs: startMs ?? 0)
    }

    /// Before a document replay: everything restarts except the malformed count.
    private mutating func reset() {
        let malformed = state.malformedLines
        state = initialState
        state.malformedLines = malformed
        sessionId = nil
        startMs = nil
        pendingStartMs = nil
        markerHash = nil
        seenToolCalls = []
        responses = [:]
    }
}

/// Project names of Gemini CLI project folders (METRICS 4.6), read once per folder.
final class GeminiProjects: Sendable {
    struct Project: Equatable, Sendable {
        var name: String?
        /// The `.project_root` content (METRICS 10.6); nil when the name came from the registry.
        var root: String?
    }

    static let shared = GeminiProjects()
    private static let maxFileBytes = 1 << 20

    private let cache = OSAllocatedUnfairLock(initialState: [String: Project]())

    /// `<projectDir>/.project_root`, else the `projects.json` registry next to the root; nil outside a project folder.
    func project(forSessionAt path: String) -> Project? {
        guard let directory = Self.projectDirectory(ofSessionAt: path) else { return nil }
        if let cached = cache.withLock({ $0[directory] }) { return cached }
        let project = Self.lookUp(directory)
        cache.withLock { $0[directory] = project }
        return project
    }

    static func projectDirectory(ofSessionAt path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == "chats" { return (parent as NSString).deletingLastPathComponent }
        let grandparent = (parent as NSString).deletingLastPathComponent
        if (grandparent as NSString).lastPathComponent == "chats", path.split(separator: "/").count >= 4 {
            return (grandparent as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func lookUp(_ directory: String) -> Project {
        if let data = read((directory as NSString).appendingPathComponent(".project_root")) {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Project(name: basename(text), root: text.isEmpty ? nil : text)
        }
        let registry = (((directory as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("projects.json")
        guard let data = read(registry) else { return Project() }
        let slug = (directory as NSString).lastPathComponent
        let name = data.withUnsafeBytes { bytes in
            Self.registryRoot(bytes, slug: slug).flatMap(basename)
        }
        return Project(name: name)
    }

    /// The first `projects` key whose value is `slug`, in document order.
    private static func registryRoot(_ bytes: UnsafeRawBufferPointer, slug: String) -> String? {
        var scanner = JSONScanner(bytes)
        do {
            try scanner.beginObject()
            var found: String?
            while let key = try scanner.nextMember() {
                guard scanner.key(key, is: "projects"), try scanner.beginObjectIfPresent() else {
                    try scanner.skipValue()
                    continue
                }
                found = nil
                while let entry = try scanner.nextMember() {
                    let root = scanner.string(of: entry)
                    if try scanner.readString() == slug, found == nil { found = root }
                }
            }
            return found
        } catch {
            return nil
        }
    }

    /// Last non-empty component, splitting on `/` and `\`.
    private static func basename(_ path: String) -> String? {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    private static func read(_ path: String) -> Data? {
        guard let stat = FileStat.lstat(path), stat.isRegularFile, stat.size <= maxFileBytes else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}
