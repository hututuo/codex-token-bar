import Foundation

/// Computes the daily history (METRICS 8): every transcript of the enabled sources (plus Codex `archived_sessions`,
/// every omp root and every Antigravity conversation database) and every OpenCode session, parsed completely with
/// the live rules, in startup order, incrementally against a `HistoryDatabase`.
///
/// Not thread-safe: one owner (a serial queue) drives it.
final class HistoryAnalyzer {
    /// Bumped whenever a parser change alters results; stored files of other versions are analysed again.
    /// 2: per-model measured output and time (METRICS 8). 3: cost (METRICS 9.7).
    static let analysisVersion: Int64 = 4
    /// The current price table version of the last complete run; when it changes, files with unpriced responses are
    /// analysed again (METRICS 9.7).
    static let priceVersionKey = "priceTableVersion"
    static let opencodeFamily = "opencode"
    static let maxWorkers = 4

    struct Options: Sendable {
        var timeZone: TimeZone
        var analysisVersion: Int64 = HistoryAnalyzer.analysisVersion
        var workers: Int = HistoryAnalyzer.defaultWorkers
        /// Contributions are written in batches at least this often.
        var saveIntervalMs: Int64 = 1500

        init(timeZone: TimeZone = .current) {
            self.timeZone = timeZone
        }
    }

    struct Progress: Equatable, Sendable {
        var filesDone = 0
        var filesTotal = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0

        var fraction: Double {
            if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
            return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 1
        }
    }

    struct Report: Equatable, Sendable {
        var filesDiscovered = 0
        var filesAnalyzed = 0
        var bytesAnalyzed: Int64 = 0
        var sessionsAnalyzed = 0
        var filesUnreadable = 0
        var durationMs: Double = 0
        var cancelled = false
    }

    /// Half the cores, at most four: the first analysis stays short without crowding the machine.
    static var defaultWorkers: Int {
        max(2, min(maxWorkers, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    let database: HistoryDatabase
    /// Shared with the live engine in the app, so today is priced alike (METRICS 9.6).
    let pricing: PriceBook
    private(set) var entries: [String: HistoryDatabase.Entry]
    private var peaks: [String: Double]
    private var indexes: [String: DirectoryIndex] = [:]

    init(database: HistoryDatabase, pricing: PriceBook = PriceBook()) throws {
        self.database = database
        self.pricing = pricing
        entries = try database.loadEntries()
        peaks = try database.peaks()
        let repaired = pricing.restore(bindings: try database.priceBindings(), tables: try database.priceTables())
        if !repaired.isEmpty {
            PricingLog.logger.notice("Price bindings without a valid table rebound to the current table: \(repaired.count, privacy: .public)")
        }
        try saveBindings()
    }

    /// Stores the dates bound since the last save, with a copy of each referenced table.
    func saveBindings() throws {
        let bindings = pricing.takeNewBindings()
        guard !bindings.isEmpty else { return }
        let pricing = self.pricing
        try database.savePriceBindings(bindings) { pricing.table(version: $0)?.data }
    }

    // MARK: - Planning

    private struct PlannedFile {
        var path: String
        var family: TranscriptFamily
        var root: String
        /// For an Antigravity database, the `.db` with its `-wal` folded in.
        var stat: FileStat
        var previous: HistoryDatabase.Entry?
    }

    private struct PlannedSession {
        var info: OpencodeSessionInfo
        var identity: (rows: Int64, modified: Int64)
        var previous: HistoryDatabase.Entry?
    }

    private struct PlannedZcodeSession {
        var path: String
        var records: [ResponseRecord]
        var modified: Int64
        var previous: HistoryDatabase.Entry?
    }

    private struct Plan {
        var files: [PlannedFile] = []
        var discovered = 0
        var opencode: (database: OpencodeDatabase, sessions: [PlannedSession], identity: String)?
        var opencodeIdentity: String?
        var zcode: [PlannedZcodeSession] = []
        var zcodeIdentity: String?

        var bytes: Int64 { files.reduce(0) { $0 + $1.stat.size } }
    }

    /// The work a run would do: discovered files whose identity or analysis version changed, and changed OpenCode
    /// sessions; after a price table change also those with unpriced responses. Cheap when nothing changed.
    private func plan(configuration: MonitorConfiguration, options: Options, zoneChanged: Bool, repricing: Bool) throws -> Plan {
        var plan = Plan()
        var seen: Set<String> = []
        for (family, root) in Self.roots(configuration) {
            guard TranscriptDiscovery.isAvailable(root: root) else { continue }
            // The daily history has no file-count limit (METRICS 8).
            var index = indexes[root] ?? DirectoryIndex(root: root, names: family.names, maxCandidates: .max)
            let paths = index.scan()
            indexes[root] = index
            for path in paths where seen.insert(path).inserted {
                guard let stat = family.stat(path) else { continue }
                plan.discovered += 1
                let previous = entries[path]
                if let previous, !zoneChanged, previous.version == options.analysisVersion,
                   previous.family == family.rawValue, previous.size == stat.size, previous.modified == stat.modifiedNs,
                   !(repricing && previous.hasUnpriced) {
                    continue
                }
                plan.files.append(PlannedFile(path: path, family: family, root: root, stat: stat, previous: previous))
            }
        }
        plan.files.sort { lhs, rhs in
            TranscriptDiscovery.startupOrder(DiscoveredFile(path: lhs.path, stat: lhs.stat), DiscoveredFile(path: rhs.path, stat: rhs.stat))
        }
        if configuration.readsOpencode {
            try planOpencode(configuration: configuration, options: options, zoneChanged: zoneChanged, repricing: repricing, into: &plan)
        }
        if configuration.readsZcode {
            try planZcode(configuration: configuration, options: options, zoneChanged: zoneChanged, repricing: repricing, into: &plan)
        }
        return plan
    }

    private func planZcode(configuration: MonitorConfiguration, options: Options, zoneChanged: Bool,
                           repricing: Bool, into plan: inout Plan) throws {
        let path = ZcodeDatabase.databasePath(forRoot: configuration.resolvedZcodeRoot)
        guard let stat = FileStat.stat(path), stat.isRegularFile else { return }
        plan.discovered += 1
        let wal = FileStat.stat(path + "-wal")
        let identity = [path, "\(stat.identity.device):\(stat.identity.inode)", "\(stat.size):\(stat.modifiedNs)",
                        wal.map { "\($0.size):\($0.modifiedNs)" } ?? "-", "v\(options.analysisVersion)"].joined(separator: "|")
        let reprices = repricing && entries.values.contains { $0.family == "zcode" && $0.hasUnpriced }
        if !zoneChanged, !reprices, try database.meta("zcode") == identity { return }
        guard let source = try? ZcodeDatabase(path: path), let batch = try? source.read() else { return }
        plan.zcodeIdentity = identity
        let grouped = Dictionary(grouping: batch.rows, by: \.sessionId)
        for session in batch.sessions.sorted(by: { $0.id < $1.id }) {
            let key = source.agentId(session.id)
            let records = (grouped[session.id] ?? []).compactMap(source.record)
            plan.zcode.append(PlannedZcodeSession(path: key, records: records,
                                                  modified: max(stat.modifiedNs, wal?.modifiedNs ?? 0), previous: entries[key]))
        }
    }

    private func planOpencode(
        configuration: MonitorConfiguration,
        options: Options,
        zoneChanged: Bool,
        repricing: Bool,
        into plan: inout Plan
    ) throws {
        let path = OpencodeDatabase.databasePath(forRoot: configuration.resolvedOpencodeRoot)
        guard let stat = FileStat.stat(path), stat.isRegularFile else { return }
        plan.discovered += 1
        let wal = FileStat.stat(path + "-wal")
        let identity = [path, "\(stat.identity.device):\(stat.identity.inode)", "\(stat.size):\(stat.modifiedNs)",
                        wal.map { "\($0.size):\($0.modifiedNs)" } ?? "-", "v\(options.analysisVersion)"].joined(separator: "|")
        let reprices = repricing && entries.contains { $0.value.family == Self.opencodeFamily && $0.value.hasUnpriced }
        if !zoneChanged, !reprices, try database.meta("opencode") == identity { return }
        // A busy, unreadable or unsupported database is tried again on the next run.
        guard let opencode = try? OpencodeDatabase(path: path), let activity = try? opencode.sessionActivity(),
              let infos = try? opencode.sessions() else { return }
        plan.opencodeIdentity = identity
        var sessions: [PlannedSession] = []
        for info in infos.sorted(by: { $0.id < $1.id }) {
            let rows = activity[info.id]
            let modified = max(info.updatedMs, rows?.lastUpdatedMs ?? 0)
            let previous = entries[OpencodeRules.agentId(session: info.id)]
            let count = rows?.rows ?? 0
            if let previous, !zoneChanged, previous.version == options.analysisVersion,
               previous.size == count, previous.modified == modified, !(repricing && previous.hasUnpriced) {
                continue
            }
            sessions.append(PlannedSession(info: info, identity: (count, modified), previous: previous))
        }
        plan.opencode = (opencode, sessions, identity)
    }

    /// Transcript roots of the enabled sources (both Gemini CLI roots, every omp root, every readable Antigravity
    /// store); Codex also contributes its `archived_sessions` sibling.
    static func roots(_ configuration: MonitorConfiguration) -> [(TranscriptFamily, String)] {
        var roots: [(TranscriptFamily, String)] = []
        for family in TranscriptFamily.allCases where configuration.reads(family) {
            for root in configuration.resolvedRoots(for: family) where MonitorConfiguration.isReadable(root: root, family: family) {
                roots.append((family, root))
            }
            if family == .codex { roots.append((family, configuration.resolvedCodexArchiveRoot)) }
        }
        return roots
    }

    // MARK: - Running

    /// Analyses what changed and stores it. `progress` is called after every file with the work done so far.
    @discardableResult
    func run(
        configuration: MonitorConfiguration,
        options: Options = Options(),
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) throws -> Report {
        let started = DispatchTime.now().uptimeNanoseconds
        var report = Report()
        let zone = options.timeZone.identifier
        let storedZone = try database.meta("timeZone")
        let zoneChanged = !entries.isEmpty && storedZone != zone
        let priceVersion = String(pricing.currentVersion)
        let storedPriceVersion = try database.meta(Self.priceVersionKey)
        let repricing = !entries.isEmpty && storedPriceVersion != priceVersion
        let plan = try plan(configuration: configuration, options: options, zoneChanged: zoneChanged, repricing: repricing)
        report.filesDiscovered = plan.discovered
        let sessions = plan.opencode?.sessions ?? []
        var state = Progress(filesTotal: plan.files.count + sessions.count + plan.zcode.count, bytesTotal: plan.bytes)
        progress(state)
        func elapsedMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }

        if plan.files.isEmpty && sessions.isEmpty && plan.zcode.isEmpty {
            try finish(plan: plan, zone: zone, priceVersion: priceVersion)
            report.durationMs = elapsedMs()
            return report
        }

        var deduper = Deduper.hashed()
        let replaced = Set(plan.files.compactMap(\.previous?.id) + sessions.compactMap(\.previous?.id) + plan.zcode.compactMap(\.previous?.id))
        try database.loadKeys(excluding: replaced, into: &deduper)
        var labeler = DayLabeler(timeZone: options.timeZone)
        var pending: [(path: String, entry: HistoryDatabase.Entry, keys: [UInt64])] = []
        var lastSave = DispatchTime.now().uptimeNanoseconds

        func flush(force: Bool) throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !pending.isEmpty, force || Int64(now - lastSave) / 1_000_000 >= options.saveIntervalMs else { return }
            let ids = try database.save(pending)
            for (path, id) in ids { entries[path]?.id = id }
            try saveBindings()
            pending.removeAll(keepingCapacity: true)
            lastSave = now
        }

        if !plan.files.isEmpty {
            let jobs = plan.files.map { OrderedDecoder.Job(path: $0.path, family: $0.family, size: $0.stat.size) }
            let decoder = OrderedDecoder(jobs: jobs)
            decoder.start(workers: options.workers)
            defer {
                decoder.cancel()
                decoder.waitForWorkers()
            }
            for (index, file) in plan.files.enumerated() {
                if isCancelled() {
                    report.cancelled = true
                    break
                }
                guard let output = decoder.next() else { break }
                state.filesDone += 1
                state.bytesDone += file.stat.size
                if output.read.failed {
                    // Unreadable or vanished: keep what was stored, including its key ownership.
                    report.filesUnreadable += 1
                    if let id = file.previous?.id { deduper.insertSettled(try database.keys(ofFile: id)) }
                    progress(state)
                    continue
                }
                // Parsers bridge paths through NSString; drain those per file on this long-running thread.
                let (days, keys) = autoreleasepool { () -> ([UsageKey: DayAggregate], [UInt64]) in
                    var parser = TranscriptParser(
                        family: file.family, agentId: file.path, fileID: FileID(truncatingIfNeeded: index), root: file.root)
                    var latest: [String: ResponseRecord] = [:]
                    parser.consume(output.lines, deduper: &deduper) { latest[$0.record.key] = $0.record }
                    let days = DayAggregate.contributions(
                        of: latest.values, source: parser.state.source, labeler: &labeler, pricing: pricing)
                    return (days, deduper.finishFile())
                }
                let stat = file.family == .grokBuild ? file.family.stat(file.path) ?? output.read.stat ?? file.stat
                    : output.read.stat ?? file.stat
                let entry = HistoryDatabase.Entry(
                    id: file.previous?.id,
                    family: file.family.rawValue,
                    size: stat.size,
                    modified: stat.modifiedNs,
                    version: options.analysisVersion,
                    days: days
                )
                entries[file.path] = entry
                pending.append((file.path, entry, keys))
                report.filesAnalyzed += 1
                report.bytesAnalyzed += stat.size
                try flush(force: false)
                progress(state)
            }
        }

        var unreadSessions = 0
        if let opencode = plan.opencode, !report.cancelled {
            let fileID = TranscriptSession.opencodeFileID
            var database = opencode.database
            for session in opencode.sessions {
                // An immutable connection is only valid while OpenCode does not write (METRICS 4.5).
                if database.isStale, let reopened = try? OpencodeDatabase(path: database.path) { database = reopened }
                if isCancelled() {
                    report.cancelled = true
                    break
                }
                guard let rows = try? database.rows(session: session.info.id) else {
                    unreadSessions += 1
                    continue
                }
                var records: [ResponseRecord] = []
                for row in rows {
                    guard let record = OpencodeRules.response(for: row, session: session.info),
                          deduper.claim(row.id, for: fileID) != .otherFile else { continue }
                    records.append(record)
                }
                let keys = deduper.finishFile()
                let path = OpencodeRules.agentId(session: session.info.id)
                let entry = HistoryDatabase.Entry(
                    id: session.previous?.id,
                    family: Self.opencodeFamily,
                    size: session.identity.rows,
                    modified: session.identity.modified,
                    version: options.analysisVersion,
                    days: DayAggregate.contributions(of: records, source: .opencode, labeler: &labeler, pricing: pricing)
                )
                entries[path] = entry
                pending.append((path, entry, keys))
                report.sessionsAnalyzed += 1
                state.filesDone += 1
                try flush(force: false)
                progress(state)
            }
        }

        if !report.cancelled {
            for session in plan.zcode {
                if isCancelled() { report.cancelled = true; break }
                let records = session.records.filter { deduper.claim($0.key, for: TranscriptSession.zcodeFileID) != .otherFile }
                let keys = deduper.finishFile()
                let entry = HistoryDatabase.Entry(id: session.previous?.id, family: "zcode", size: Int64(records.count),
                                                  modified: session.modified, version: options.analysisVersion,
                                                  days: DayAggregate.contributions(of: records, source: .zcode, labeler: &labeler, pricing: pricing))
                entries[session.path] = entry
                pending.append((session.path, entry, keys))
                report.sessionsAnalyzed += 1
                state.filesDone += 1
                try flush(force: false)
                progress(state)
            }
        }

        try flush(force: true)
        try saveBindings()
        if !report.cancelled {
            try finish(plan: plan, zone: zone, priceVersion: priceVersion, opencodeComplete: unreadSessions == 0)
        }
        report.durationMs = elapsedMs()
        return report
    }

    private func finish(plan: Plan, zone: String, priceVersion: String, opencodeComplete: Bool = true) throws {
        try database.setMeta("timeZone", zone)
        try database.setMeta(Self.priceVersionKey, priceVersion)
        if opencodeComplete, let identity = plan.opencodeIdentity { try database.setMeta("opencode", identity) }
        if let identity = plan.zcodeIdentity { try database.setMeta("zcode", identity) }
    }

    // MARK: - Results

    /// Daily totals: sums over files, for the given sources, sorted by day then source.
    func days(sources: Set<SourceKind>) -> [DailyUsage] {
        var totals: [UsageKey: DayAggregate] = [:]
        for entry in entries.values {
            for (key, day) in entry.days where sources.contains(key.source) {
                totals[key, default: DayAggregate()].merge(day)
            }
        }
        return totals
            .sorted { lhs, rhs in
                lhs.key.day != rhs.key.day ? lhs.key.day < rhs.key.day : lhs.key.source.rawValue < rhs.key.source.rawValue
            }
            .map {
                $0.value.usage(day: $0.key.day, source: $0.key.source, peak: peaks[$0.key.day],
                               priceVersion: pricing.boundVersion(forDay: $0.key.day))
            }
    }

    /// Stores a day's live peak (all sources); returns true when it raised the stored value.
    @discardableResult
    func recordPeak(_ peak: Double, day: String) throws -> Bool {
        guard peak > (peaks[day] ?? 0) else { return false }
        try database.recordPeak(peak, day: day)
        peaks[day] = peak
        return true
    }
}
