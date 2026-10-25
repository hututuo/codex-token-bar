import Foundation

struct KimiParser: Sendable {
    let agentId: String
    let fileID: FileID
    private(set) var state = AgentState(source: .kimi)
    private let sessionId: String
    private let wireAgent: String
    private var pendingStartMs: Int64?
    private var provider: String?
    private var latest: [String: ResponseRecord] = [:]
    private var requestMessageId: String?

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
        let file = URL(fileURLWithPath: agentId)
        let folder = file.deletingLastPathComponent()
        if folder.deletingLastPathComponent().lastPathComponent == "agents" {
            wireAgent = folder.lastPathComponent
            let session = folder.deletingLastPathComponent().deletingLastPathComponent()
            sessionId = session.lastPathComponent
            state.isSubagent = wireAgent != "main"
            let parent = state.isSubagent ? session.appendingPathComponent("agents/main/wire.jsonl").path : nil
            state.thread = SessionThread(id: sessionId + ":" + wireAgent, parentId: parent, createdMs: 0)
            if let json = HarnessMetadata.read(session.appendingPathComponent("state.json").path),
               let cwd = json["workDir"]?.string ?? json["cwd"]?.string ?? json["work_dir"]?.string {
                state.setProject(fromWorkingDirectory: cwd)
            }
        } else {
            wireAgent = "main"
            sessionId = folder.lastPathComponent
        }
    }

    mutating func noteMalformedLine() { state.malformedLines += 1 }

    mutating func consume(_ extraction: LineExtraction<KimiLine>, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch extraction {
        case .blank: return
        case .malformed: noteMalformedLine()
        case .line(let line): consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: KimiLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard line.agent == nil || line.agent == wireAgent else { return }
        if let cwd = line.cwd { state.setProject(fromWorkingDirectory: cwd) }
        if line.hasModeSelection || line.model != nil { state.modes = ExecutionModeAdapters.kimi(line.model) }
        if let model = line.model { state.model = model }
        if let provider = line.provider { self.provider = provider }
        guard let time = line.time else { return }
        state.noteLine(at: time)
        switch line.type {
        case "llm.request":
            pendingStartMs = time
            requestMessageId = nil
            state.setPhase(.generating, at: time, inFlightStartMs: time)
        case "turn.prompt":
            state.setPhase(.generating, at: time, inFlightStartMs: time)
        case "turn.ended", "turn.cancel", "prompt.completed", "prompt.aborted":
            state.setPhase(.idle, at: time)
            pendingStartMs = nil
        case "context.append_loop_event":
            if line.event == "step.begin" {
                pendingStartMs = pendingStartMs ?? time
                state.setPhase(.generating, at: time, inFlightStartMs: pendingStartMs)
            } else if line.event == "tool.call" {
                state.setPhase(.tools, at: time)
            } else if line.event == "step.end" {
                consumeMessage(line, time: time, deduper: &deduper, emit: emit)
            }
        case "context.append_message", "agent.message.appended", "human.agent.message.appended":
            if line.role == "assistant" { consumeMessage(line, time: time, deduper: &deduper, emit: emit) }
        default: break
        }
    }

    private mutating func consumeMessage(_ line: KimiLine, time: Int64, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard !line.partial, let usage = line.usage else { return }
        let mirroredId = line.type == "context.append_loop_event" ? requestMessageId : nil
        let identity = line.messageId ?? mirroredId ?? "\(sessionId):\(line.agent ?? wireAgent):\(time)"
        let key = "kimi:" + identity
        requestMessageId = identity
        let previous = latest[key]
        let start = previous?.startMs ?? pendingStartMs ?? line.durationMs.map { time - $0 }
        let end = previous?.endMs ?? time
        let record = ResponseRecord(key: key, source: .kimi, agentId: agentId, model: line.model ?? state.model,
                                    startMs: start, endMs: end, usage: usage, provider: line.provider ?? provider, modes: state.modes)
        guard record != previous, deduper.claim(key, for: fileID) != .otherFile else { return }
        latest[key] = record
        emit(ResponseUpsert(record: record, isCompletion: previous == nil))
        pendingStartMs = nil
        state.setPhase(line.hasTools ? .tools : .idle, at: time)
    }
}
