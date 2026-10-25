import Foundation

/// Follows OpenCode's database for the live monitor (METRICS 4.5, 5.2).
///
/// Every session is one agent. Rows are kept per session (reduced to the fields that matter) so the state can be
/// replayed in `seq` order whenever any row of the session changes.
///
/// Not thread-safe: owned by `TranscriptSession` on its serial queue.
final class OpencodeSource {
    enum Status: Equatable, Sendable {
        case missing
        case unreadable
        case unsupported
        case ready
    }

    /// What changed in one read.
    struct Update {
        var upserts: [(upsert: ResponseUpsert, project: String)] = []
        /// Agent id → state, for sessions whose state may have changed.
        var agents: [String: AgentState] = [:]
        var removedAgents: [String] = []
        /// Every previously reported agent is gone (the database vanished or was replaced).
        var reset = false

        var isEmpty: Bool { upserts.isEmpty && agents.isEmpty && removedAgents.isEmpty && !reset }
    }

    /// Rows created or updated this close to a cursor are read again, in case they were committed out of order.
    static let cursorOverlapMs: Int64 = 2000
    /// Rows updated this recently are re-read by id on every change.
    static let recentRowMs: Int64 = 60_000
    static let maxWatchedRows = 256
    /// In-flight rows that have not changed for this long are no longer re-read by id.
    static let staleInFlightMs: Int64 = 30 * 60_000
    /// Sessions quiet for this long drop their rows from memory; later rows start a fresh replay.
    static let compactAfterMs: Int64 = 2 * 3600_000

    private struct TrackedSession {
        var info: OpencodeSessionInfo
        var rows: [String: OpencodeRow] = [:]
        /// Latest `time_updated` of the rows read (or the session's at startup when its rows were not read).
        var rowWatermark: Int64?
        var emitted: [String: ResponseRecord] = [:]
        var state: AgentState

        init(info: OpencodeSessionInfo, rowWatermark: Int64? = nil) {
            self.info = info
            self.rowWatermark = rowWatermark
            state = OpencodeRules.state(of: info, rows: [])
        }

        var project: String {
            let name = info.directory.map { ($0 as NSString).lastPathComponent } ?? ""
            return name.isEmpty ? info.id : name
        }
    }

    let rootPath: String
    let databasePath: String
    let fileID: FileID
    private(set) var status: Status = .missing
    private(set) var canonicalDatabasePath: String?
    private var database: OpencodeDatabase?
    private var databaseStat: FileStat?
    private var walStat: FileStat?
    private var sessions: [String: TrackedSession] = [:]
    private var rowSessions: [String: String] = [:]
    /// Row id → (`time_updated`, still unfinished): rows re-read by id on every change.
    private var watchedRows: [String: (updated: Int64, unfinished: Bool)] = [:]
    /// The last startup read failed (for example the database stayed busy); the next rediscovery reads again.
    private var seedFailed = false
    private var createdCursor: Int64?
    private var sessionCursor: Int64?
    private var newestRowUpdate: Int64 = 0

    init(root: String, fileID: FileID) {
        rootPath = root
        databasePath = OpencodeDatabase.databasePath(forRoot: root)
        self.fileID = fileID
    }

    // MARK: - Availability

    /// The database file exists (it may still be unreadable or unsupported).
    var exists: Bool { status != .missing }
    var isReady: Bool { status == .ready }

    /// The folder FSEvents watches for `opencode.db` and `opencode.db-wal`.
    var watchedDirectory: String? {
        canonicalDatabasePath.map { ($0 as NSString).deletingLastPathComponent }
    }

    func matches(canonicalPath path: String) -> Bool {
        guard let canonicalDatabasePath else { return false }
        return path == canonicalDatabasePath || path == canonicalDatabasePath + "-wal"
    }

    /// Opens the database when it appeared, closes it when it vanished or was replaced. Returns true when the
    /// status changed or the database must be read again from the start.
    @discardableResult
    func refreshAvailability() -> Bool {
        let stat = FileStat.stat(databasePath)
        guard let stat, stat.isRegularFile else {
            let changed = status != .missing
            close(status: .missing)
            return changed
        }
        if database != nil, databaseStat?.identity == stat.identity { return seedFailed }
        let previous = status
        close(status: .missing)
        canonicalDatabasePath = Self.canonical(databasePath)
        do {
            database = try OpencodeDatabase(path: databasePath)
            status = .ready
        } catch .missing {
            status = .missing
        } catch .unsupported {
            status = .unsupported
        } catch {
            status = .unreadable
        }
        databaseStat = stat
        walStat = FileStat.stat(databasePath + "-wal")
        return status != previous || status == .ready
    }

    /// Drops an immutable connection once `opencode.db` changed or a `-wal` appeared and reopens it, normally
    /// `mode=ro` now (METRICS 4.5). A replaced file is left to `refreshAvailability`, which reads it from the start.
    private func reopenIfStale() {
        guard let database, database.isStale else { return }
        self.database = nil
        guard let stat = FileStat.stat(databasePath), stat.isRegularFile, stat.identity == databaseStat?.identity else { return }
        do {
            self.database = try OpencodeDatabase(path: databasePath)
            status = .ready
        } catch .unsupported {
            status = .unsupported
        } catch {
            status = .unreadable
        }
    }

    private func close(status newStatus: Status) {
        database = nil
        databaseStat = nil
        walStat = nil
        status = newStatus
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Reading

    /// Startup read (METRICS 5.2): sessions updated since `todayStartMs - 15 min` are read completely; older sessions
    /// are known by their metadata only and continue from their current state.
    func seed(todayStartMs: Int64, deduper: inout Deduper) -> Update {
        var update = Update()
        update.reset = true
        let removed = sessions.keys.map(OpencodeRules.agentId)
        sessions = [:]
        rowSessions = [:]
        watchedRows = [:]
        createdCursor = nil
        sessionCursor = nil
        newestRowUpdate = 0
        reopenIfStale()
        guard let database else {
            update.removedAgents = removed
            return update
        }
        let threshold = todayStartMs - TranscriptSession.startupLookbackMs
        seedFailed = false
        do {
            createdCursor = try database.maxCreatedMs() ?? 0
            for info in try database.sessions().sorted(by: { $0.id < $1.id }) {
                sessionCursor = max(sessionCursor ?? info.updatedMs, info.updatedMs)
                guard info.updatedMs >= threshold else {
                    sessions[info.id] = TrackedSession(info: info, rowWatermark: info.updatedMs)
                    continue
                }
                sessions[info.id] = TrackedSession(info: info)
                let rows = try database.rows(session: info.id)
                apply(rows, toSession: info.id, deduper: &deduper, into: &update)
            }
        } catch {
            seedFailed = true
        }
        update.removedAgents = removed.filter { update.agents[$0] == nil }
        return update
    }

    /// Reads what changed since the last read (METRICS 5.2).
    func refresh(deduper: inout Deduper) -> Update {
        var update = Update()
        reopenIfStale()
        guard status == .ready, let database else { return update }
        databaseStat = FileStat.stat(databasePath) ?? databaseStat
        walStat = FileStat.stat(databasePath + "-wal")
        do {
            var advanced: [String] = []
            for info in try database.sessions(updatedSince: (sessionCursor ?? 0) - Self.cursorOverlapMs) {
                sessionCursor = max(sessionCursor ?? info.updatedMs, info.updatedMs)
                if var tracked = sessions[info.id] {
                    guard info != tracked.info else { continue }
                    let moved = info.updatedMs > tracked.info.updatedMs
                    tracked.info = info
                    sessions[info.id] = tracked
                    update.agents[OpencodeRules.agentId(session: info.id)] = recomputeState(info.id)
                    if moved { advanced.append(info.id) }
                } else {
                    sessions[info.id] = TrackedSession(info: info)
                    advanced.append(info.id)
                }
            }

            let known = { [self] (id: String, updated: Int64) -> Bool in
                guard let session = rowSessions[id] else { return false }
                return sessions[session]?.rows[id]?.timeUpdated == updated
            }
            var changed: [String: [OpencodeRow]] = [:]
            let since = (createdCursor ?? 0) - Self.cursorOverlapMs
            for (session, row) in try database.rows(createdSince: since, skip: known) {
                changed[session, default: []].append(row)
            }
            for (session, row) in try database.rows(ids: Array(watchedRows.keys), skip: known) {
                changed[session, default: []].append(row)
            }
            for id in advanced {
                let watermark = sessions[id]?.rowWatermark.map { $0 - Self.cursorOverlapMs }
                changed[id, default: []].append(contentsOf: try database.rows(session: id, updatedSince: watermark, skip: known))
            }
            for (session, rows) in changed.sorted(by: { $0.key < $1.key }) where !rows.isEmpty {
                if sessions[session] == nil { continue }
                apply(rows, toSession: session, deduper: &deduper, into: &update)
            }
        } catch {
            // A busy or vanished database is retried on the next change, poll or rediscovery.
        }
        return update
    }

    /// The 1-second fallback: reads again when the database or its WAL changed.
    func refreshIfChanged(deduper: inout Deduper) -> Update? {
        guard status == .ready else { return nil }
        let db = FileStat.stat(databasePath)
        let wal = FileStat.stat(databasePath + "-wal")
        guard db != databaseStat || wal != walStat else { return nil }
        if db?.identity != databaseStat?.identity { return nil }
        return refresh(deduper: &deduper)
    }

    /// Periodic check: drops deleted sessions, picks up changed metadata and releases rows of quiet sessions.
    func rediscover(nowMs: Int64, deduper: inout Deduper) -> Update {
        var update = refresh(deduper: &deduper)
        guard status == .ready, let database, let all = try? database.sessions() else { return update }
        let present = Set(all.map(\.id))
        for id in sessions.keys where !present.contains(id) {
            if let rows = sessions.removeValue(forKey: id)?.rows.keys {
                for row in rows { rowSessions[row] = nil; watchedRows[row] = nil }
            }
            update.removedAgents.append(OpencodeRules.agentId(session: id))
            update.agents[OpencodeRules.agentId(session: id)] = nil
        }
        for (id, tracked) in sessions where !tracked.rows.isEmpty && tracked.state.phase != .generating {
            guard let last = tracked.state.lastLineMs, nowMs - last > Self.compactAfterMs else { continue }
            for row in tracked.rows.keys { rowSessions[row] = nil; watchedRows[row] = nil }
            sessions[id]?.rows = [:]
            sessions[id]?.emitted = [:]
        }
        return update
    }

    private func apply(_ rows: [OpencodeRow], toSession id: String, deduper: inout Deduper, into update: inout Update) {
        guard var tracked = sessions[id] else { return }
        for row in rows.sorted(by: { $0.seq < $1.seq }) {
            if let previous = tracked.rows[row.id], previous.timeUpdated == row.timeUpdated, previous == row { continue }
            tracked.rows[row.id] = row
            rowSessions[row.id] = id
            tracked.rowWatermark = max(tracked.rowWatermark ?? row.timeUpdated, row.timeUpdated)
            newestRowUpdate = max(newestRowUpdate, row.timeUpdated)
            createdCursor = max(createdCursor ?? row.timeCreated, row.timeCreated)
            watch(row)
            guard let record = OpencodeRules.response(for: row, session: tracked.info) else { continue }
            let previous = tracked.emitted[row.id]
            if previous == nil, deduper.claim(row.id, for: fileID) == .otherFile { continue }
            guard previous != record else { continue }
            tracked.emitted[row.id] = record
            update.upserts.append((ResponseUpsert(record: record, isCompletion: previous == nil), tracked.project))
        }
        sessions[id] = tracked
        update.agents[OpencodeRules.agentId(session: id)] = recomputeState(id)
        pruneWatchedRows()
    }

    private func recomputeState(_ id: String) -> AgentState? {
        guard var tracked = sessions[id] else { return nil }
        tracked.state = OpencodeRules.state(of: tracked.info, rows: tracked.rows.values.sorted { $0.seq < $1.seq })
        sessions[id] = tracked
        return tracked.state
    }

    /// Rows still in flight, unfinished or recently updated are re-read by id on every change.
    private func watch(_ row: OpencodeRow) {
        let unfinished: Bool = switch row.kind {
        case .assistant: row.data.map { $0.streamed == nil || $0.completed == nil } ?? false
        case .compaction: row.data.map { $0.completed == nil } ?? false
        case .idle, .other: false
        }
        if unfinished || row.timeUpdated >= newestRowUpdate - Self.recentRowMs {
            watchedRows[row.id] = (row.timeUpdated, unfinished)
        } else {
            watchedRows[row.id] = nil
        }
    }

    /// Finished rows stay watched for `recentRowMs`, unfinished ones for `staleInFlightMs`; the newest are kept.
    private func pruneWatchedRows() {
        watchedRows = watchedRows.filter { _, row in
            row.updated >= newestRowUpdate - (row.unfinished ? Self.staleInFlightMs : Self.recentRowMs)
        }
        guard watchedRows.count > Self.maxWatchedRows else { return }
        let kept = watchedRows.sorted { $0.value.updated > $1.value.updated }.prefix(Self.maxWatchedRows)
        watchedRows = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: - Agents

    /// Agent id → state of every session that has at least one row read.
    var agentStates: [String: AgentState] {
        var states: [String: AgentState] = [:]
        for (id, tracked) in sessions where tracked.state.lastLineMs != nil {
            states[OpencodeRules.agentId(session: id)] = tracked.state
        }
        return states
    }

    /// `opencode:<id>` → `opencode:<parent_id>` when the parent session exists (METRICS 4.5, 6.7).
    var parentLinks: [String: String] {
        var links: [String: String] = [:]
        for (id, tracked) in sessions {
            guard let parent = tracked.info.parentId, parent != id, sessions[parent] != nil else { continue }
            links[OpencodeRules.agentId(session: id)] = OpencodeRules.agentId(session: parent)
        }
        return links
    }

    func project(ofAgent agentId: String) -> String? {
        guard agentId.hasPrefix(OpencodeRules.agentPrefix) else { return nil }
        return sessions[String(agentId.dropFirst(OpencodeRules.agentPrefix.count))]?.project
    }

    /// Sessions with a row updated today.
    func activeSessionCount(todayStartMs: Int64) -> Int {
        sessions.values.reduce(0) { count, tracked in
            count + ((tracked.state.lastLineMs ?? .min) >= todayStartMs ? 1 : 0)
        }
    }

    var malformedRows: Int {
        sessions.values.reduce(0) { $0 + $1.state.malformedLines }
    }

    var databaseSize: Int64 { databaseStat?.size ?? 0 }
}
