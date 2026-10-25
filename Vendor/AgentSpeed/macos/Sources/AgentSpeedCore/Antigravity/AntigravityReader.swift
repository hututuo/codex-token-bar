import Foundation

/// Follows one Antigravity conversation database (METRICS 5.4): a complete first read, then incremental reads of the
/// rows above the cursors plus the current versions of the steps last seen open. A new identity of the `.db` resets
/// it. The connection is opened lazily; an immutable one is dropped after every read (it is only valid until the next
/// change), a `mode=ro` one stays open until its owner closes it.
struct AntigravityReader: Sendable {
    let path: String
    private(set) var cursors = AntigravityDatabase.Cursors()
    private var openSteps: Set<Int64> = []
    private var identity: FileIdentity?
    /// Not read at startup: the first read is complete and runs off the live loop (METRICS 5.4).
    private(set) var defersFirstRead: Bool
    private var database: AntigravityDatabase?

    init(path: String, start: FileTailer.Start = .beginning) {
        self.path = path
        defersFirstRead = start != .beginning
    }

    var hasOpenConnection: Bool { database != nil }

    mutating func closeConnection() {
        database = nil
    }

    mutating func read() -> (AntigravityBatch?, FileTailer.ReadResult) {
        var result = FileTailer.ReadResult()
        guard let stat = FileStat.databaseStat(path) else {
            database = nil
            result.failed = true
            return (nil, result)
        }
        result.stat = stat
        if let identity, identity != stat.identity {
            database = nil
            cursors = AntigravityDatabase.Cursors()
            openSteps = []
            result.didReset = true
        }
        identity = stat.identity
        if database?.isStale == true { database = nil }
        let reused = database != nil
        let complete = cursors == .complete
        var outcome = attempt()
        if case .failed = outcome, reused {
            // The files under a kept connection can change (the server removed its WAL): retry once, reopened.
            outcome = attempt()
        }
        switch outcome {
        case .unsupported:
            defersFirstRead = false
            result.bytesRead = 1
            return (AntigravityBatch(unsupported: true), result)
        case .failed:
            result.failed = true
            return (nil, result)
        case .read(let batch):
            advance(over: batch)
            defersFirstRead = false
            let rows = batch.steps.count + batch.generations.count + batch.executors.count + (batch.trajectory == nil ? 0 : 1)
            result.bytesRead = complete ? max(1, Int(stat.size)) : rows
            return (batch, result)
        }
    }

    private enum Outcome {
        case read(AntigravityBatch)
        case unsupported
        case failed
    }

    /// One query pass, opening the connection when needed. A failed connection is dropped; an immutable one is
    /// dropped after every read.
    private mutating func attempt() -> Outcome {
        if database == nil {
            do {
                database = try AntigravityDatabase(path: path)
            } catch .unsupported {
                return .unsupported
            } catch {
                return .failed
            }
        }
        guard let database else { return .failed }
        do {
            let batch = try database.read(after: cursors, openSteps: openSteps)
            if database.isImmutable { self.database = nil }
            return .read(batch)
        } catch {
            self.database = nil
            return .failed
        }
    }

    private mutating func advance(over batch: AntigravityBatch) {
        if batch.trajectory != nil { cursors.trajectoryFound = true }
        for row in batch.generations { cursors.generations = max(cursors.generations, row.idx) }
        for row in batch.executors { cursors.executors = max(cursors.executors, row.idx) }
        for row in batch.steps {
            cursors.steps = max(cursors.steps, row.idx)
            if AntigravityStep.isOpen(row.status) {
                openSteps.insert(row.idx)
            } else {
                openSteps.remove(row.idx)
            }
        }
    }
}
