import Foundation

final class ZcodeSource {
    struct Update {
        var upserts: [(ResponseUpsert, String)] = []
        var agents: [String: AgentState] = [:]
        var removedAgents: [String] = []
        var isEmpty: Bool { upserts.isEmpty && agents.isEmpty && removedAgents.isEmpty }
    }

    let rootPath: String
    var databasePath: String { ZcodeDatabase.databasePath(forRoot: rootPath) }
    private(set) var status: OpencodeSource.Status = .missing
    private(set) var parentLinks: [String: String] = [:]
    private var stat: FileStat?
    private var walStat: FileStat?
    private var emitted: [String: ResponseRecord] = [:]
    private var states: [String: AgentState] = [:]
    private var watermark: Int64?
    private var needsRead = true
    private let fileID: FileID

    init(root: String, fileID: FileID) {
        rootPath = root
        self.fileID = fileID
    }

    var exists: Bool { status != .missing }
    var isReady: Bool { status == .ready }
    var watchedDirectory: String? { FileStat.stat(databasePath)?.isRegularFile == true ? (databasePath as NSString).deletingLastPathComponent : nil }
    var databaseSize: Int64 { (FileStat.stat(databasePath)?.size ?? 0) + (FileStat.stat(databasePath + "-wal")?.size ?? 0) }

    func matches(canonicalPath path: String) -> Bool {
        guard let resolved = realpath(databasePath, nil) else { return path == databasePath || path == databasePath + "-wal" }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return path == canonical || path == canonical + "-wal"
    }

    @discardableResult
    func refreshAvailability() -> Bool {
        let current = FileStat.stat(databasePath)
        let available = current?.isRegularFile == true
        let changed = available != exists || current?.identity != stat?.identity
        if !available { status = .missing }
        if available, changed || status != .ready {
            do {
                _ = try ZcodeDatabase(path: databasePath)
                status = .ready
            } catch let error as SQLiteError {
                status = error.code & 0xFF == 1 ? .unsupported : .unreadable
            } catch {
                status = .unreadable
            }
        }
        if changed {
            watermark = nil
            needsRead = true
        }
        return changed
    }

    func seed(todayStartMs: Int64, deduper: inout Deduper) -> Update {
        watermark = todayStartMs - TranscriptSession.startupLookbackMs
        needsRead = true
        return refresh(deduper: &deduper)
    }

    func refreshIfChanged(deduper: inout Deduper) -> Update? {
        let current = FileStat.stat(databasePath), wal = FileStat.stat(databasePath + "-wal")
        guard needsRead || current != stat || wal != walStat else { return nil }
        return refresh(deduper: &deduper)
    }

    func refresh(deduper: inout Deduper) -> Update {
        var update = Update()
        let current = FileStat.stat(databasePath)
        guard current?.isRegularFile == true else {
            status = .missing
            update.removedAgents = Array(states.keys)
            states = [:]
            parentLinks = [:]
            return update
        }
        if let stat, current?.identity != stat.identity {
            update.removedAgents = Array(states.keys)
            emitted = [:]
            states = [:]
            watermark = nil
        }
        do {
            let database = try ZcodeDatabase(path: databasePath)
            let batch = try database.read(sinceMs: watermark.map { $0 - 2000 })
            status = .ready
            needsRead = false
            var next: [String: AgentState] = [:]
            var links: [String: String] = [:]
            for session in batch.sessions {
                let id = database.agentId(session.id)
                var state = states[id] ?? AgentState(source: .zcode)
                state.thread = SessionThread(id: session.id, parentId: session.parentId, createdMs: session.createdMs)
                state.isSubagent = session.parentId != nil
                if let directory = session.directory { state.setProject(fromWorkingDirectory: directory) }
                state.noteLine(at: session.updatedMs)
                next[id] = state
                if let parent = session.parentId { links[id] = database.agentId(parent) }
            }
            var rowTimes: [String: Int64] = [:]
            for row in batch.rows {
                let id = database.agentId(row.sessionId)
                guard var state = next[id] else { continue }
                state.model = row.model ?? state.model
                state.modes = row.modes
                let time = row.endMs ?? row.startMs
                rowTimes[row.sessionId] = max(rowTimes[row.sessionId] ?? time, time)
                state.noteLine(at: time)
                if row.status == "running" {
                    state.setPhase(.generating, at: row.startMs, inFlightStartMs: row.startMs)
                } else if time >= (state.phaseSinceMs ?? Int64.min) {
                    state.setPhase(.idle, at: time)
                }
                next[id] = state
                watermark = max(watermark ?? time, time)
                guard let record = database.record(row), emitted[record.key] != record,
                      deduper.claim(record.key, for: fileID) != .otherFile else { continue }
                let isCompletion = emitted[record.key] == nil
                emitted[record.key] = record
                update.upserts.append((ResponseUpsert(record: record, isCompletion: isCompletion), state.project ?? row.sessionId))
            }
            for (session, message) in batch.messageStates {
                let id = database.agentId(session)
                guard var state = next[id], let time = message.lastLineMs,
                      time >= (rowTimes[session] ?? Int64.min) else { continue }
                state.model = message.model ?? state.model
                if !message.modes.facts.isEmpty { state.modes = message.modes }
                state.noteLine(at: time)
                state.setPhase(message.phase, at: message.phaseSinceMs ?? time, inFlightStartMs: message.inFlightStartMs)
                next[id] = state
            }
            for id in states.keys where next[id] == nil { update.removedAgents.append(id) }
            update.agents = next.filter { states[$0.key] != $0.value }
            if let watermark { emitted = emitted.filter { $0.value.endMs >= watermark - 2 * 3600_000 } }
            states = next
            parentLinks = links
            stat = current
            walStat = FileStat.stat(databasePath + "-wal")
        } catch let error as SQLiteError {
            status = error.code & 0xFF == 1 ? .unsupported : .unreadable
        } catch {
            status = .unreadable
        }
        return update
    }

    func activeSessionCount(todayStartMs: Int64) -> Int {
        states.values.filter { !$0.isSubagent && ($0.lastLineMs ?? 0) >= todayStartMs }.count
    }
}
