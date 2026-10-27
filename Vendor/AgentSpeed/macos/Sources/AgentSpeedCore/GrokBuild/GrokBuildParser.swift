import Foundation

struct GrokBuildParser: Sendable {
    private struct Pending: Sendable {
        var time: Int64
        var prompt: String
        var batch: GrokBuildUsage
    }

    static let pendingLimit = 256
    let agentId: String
    let fileID: FileID
    private(set) var state = AgentState(source: .grokBuild)
    private(set) var partialHistory = false
    private var pendingStartMs: Int64?
    private var suppressUsage = false
    private var latest: [String: ResponseRecord] = [:]
    private var pending: [Pending] = []
    private let sessionId: String
    private let sessionFolder: URL
    private var metadataStat: FileStat?

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
        sessionFolder = URL(fileURLWithPath: agentId).deletingLastPathComponent()
        sessionId = sessionFolder.lastPathComponent
        if let cwd = sessionFolder.deletingLastPathComponent().lastPathComponent.removingPercentEncoding {
            state.setProject(fromWorkingDirectory: cwd)
        }
        _ = readMetadata()
    }

    static func stat(_ path: String) -> FileStat? {
        guard var stat = FileStat.lstat(path), stat.isRegularFile else { return nil }
        let summary = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("summary.json")
        if let metadata = FileStat.lstat(summary), metadata.isRegularFile { stat.modifiedNs = max(stat.modifiedNs, metadata.modifiedNs) }
        return stat
    }

    private mutating func readMetadata() -> Bool {
        let path = sessionFolder.appendingPathComponent("summary.json").path
        guard let stat = FileStat.lstat(path), stat.isRegularFile, stat != metadataStat,
              let summary = HarnessMetadata.read(path), summary.object != nil else { return false }
        let previous = state
        metadataStat = stat
        if let cwd = summary["info"]?["cwd"]?.string { state.setProject(fromWorkingDirectory: cwd) }
        if let model = summary["current_model_id"]?.string { state.model = model }
        let parent = summary["parent_session_id"]?.string.flatMap { $0.isEmpty || $0 == sessionId ? nil : $0 }
        let kind = summary["session_kind"]?.string
        state.isSubagent = parent != nil && (kind == "subagent" || kind == "subagent_fork")
        suppressUsage = state.isSubagent
        state.thread = SessionThread(id: summary["info"]?["id"]?.string ?? sessionId,
            parentId: parent,
            createdMs: summary["created_at"]?.string.flatMap(Timestamp.parse) ?? 0)
        return previous != state
    }

    mutating func refreshMetadata(deduper: inout Deduper, emit: (ResponseUpsert) -> Void) -> Bool {
        let changed = readMetadata()
        guard metadataStat != nil, !pending.isEmpty else { return changed }
        let waiting = pending
        pending.removeAll(keepingCapacity: true)
        if !suppressUsage { for item in waiting { deliver(item, deduper: &deduper, emit: emit) } }
        return true
    }

    mutating func noteMalformedLine() { state.malformedLines += 1 }

    mutating func consume(_ extraction: LineExtraction<GrokBuildLine>, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch extraction {
        case .blank: return
        case .malformed: noteMalformedLine()
        case .line(let line): consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: GrokBuildLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        _ = refreshMetadata(deduper: &deduper, emit: emit)
        guard let time = line.time else { return }
        state.noteLine(at: time)
        if let model = line.model { state.model = model }
        switch line.kind {
        case "user_message_chunk":
            if state.phase != .generating { pendingStartMs = time }
            state.setPhase(.generating, at: time, inFlightStartMs: pendingStartMs ?? time)
        case "agent_message_chunk", "agent_thought_chunk", "response_started":
            state.setPhase(.generating, at: time, inFlightStartMs: pendingStartMs ?? time)
        case "tool_call": state.setPhase(.tools, at: time)
        case "tool_call_update":
            if line.status == "completed" {
                pendingStartMs = time
                state.setPhase(.generating, at: time, inFlightStartMs: time)
            }
        case "turn_completed":
            let prompt = line.promptId ?? line.eventId ?? "\(sessionId):\(time)"
            for batch in line.batches {
                let item = Pending(time: time, prompt: prompt, batch: batch)
                if metadataStat == nil {
                    if pending.count == Self.pendingLimit { pending.removeFirst(); partialHistory = true }
                    pending.append(item)
                } else if !suppressUsage {
                    deliver(item, deduper: &deduper, emit: emit)
                }
            }
            state.setPhase(.idle, at: time)
            pendingStartMs = nil
        case "turn_cancelled", "turn_failed":
            state.setPhase(.idle, at: time)
            pendingStartMs = nil
        default: break
        }
    }

    private mutating func deliver(_ item: Pending, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        let model = item.batch.model ?? state.model
        let key = "grok:" + item.prompt + ":" + (model ?? "unknown")
        let record = ResponseRecord(key: key, source: .grokBuild, agentId: agentId, model: model,
            startMs: item.batch.durationMs.map { item.time - $0 }, endMs: item.time,
            usage: item.batch.usage, requestCount: item.batch.requestCount)
        guard latest[key] != record, deduper.claim(key, for: fileID) != .otherFile else { return }
        let isCompletion = latest[key] == nil
        latest[key] = record
        emit(ResponseUpsert(record: record, isCompletion: isCompletion))
    }
}
