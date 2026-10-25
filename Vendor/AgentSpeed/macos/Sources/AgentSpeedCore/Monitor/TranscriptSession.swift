import Foundation
import os

/// Statistics of the startup backlog read.
public struct SeedSummary: Equatable, Sendable {
    public var filesDiscovered = 0
    public var filesRead = 0
    public var bytesRead: Int64 = 0
    public var durationMs: Double = 0
    public var partialHistory = false

    public init() {}
}

/// A live whole-file read (compressed Codex session or legacy Gemini document), prepared on the session queue and
/// performed elsewhere so live updates never pause (METRICS 5.3).
struct WholeFileRead: Sendable {
    let path: String
    let family: TranscriptFamily
    let fileID: FileID
    let reader: TranscriptReader

    func perform() -> WholeFileResult {
        var reader = self.reader
        let (lines, read) = TranscriptDecoder.decode(family, reader: &reader)
        return WholeFileResult(path: path, fileID: fileID, reader: reader, lines: lines, read: read)
    }
}

struct WholeFileResult: Sendable {
    let path: String
    let fileID: FileID
    let reader: TranscriptReader
    let lines: DecodedLines
    let read: FileTailer.ReadResult
}

/// Every transcript file of the enabled roots, the OpenCode database, their parsers, the shared dedupe set and the
/// engine.
///
/// Not thread-safe: one owner (a serial queue) drives it. Only seeding fans out, and it joins before returning.
final class TranscriptSession {
    /// Size rules of METRICS 4 and 5; tests shrink them.
    struct ReadingLimits: Sendable {
        var largeFileBytes = FileTailer.largeFileBytes
        var tailWindowBytes = FileTailer.tailWindowBytes
        var maxLineBytes = FileTailer.defaultMaxLineBytes

        static let standard = ReadingLimits()
    }

    struct Root: Sendable {
        var family: TranscriptFamily
        var path: String
        var canonicalPath: String
        var enabled: Bool
        var available: Bool
        /// False for roots that are never read (an Antigravity `*-backup` store).
        var readable = true
        /// A folder whose existence alone detects the source (WorkBuddy: the data folder that holds `projects`).
        var detectionPath: String?
        /// The root is available, or its detection folder exists (METRICS 2).
        var detected = false
    }

    static let startupLookbackMs: Int64 = 15 * 60_000
    static let hotWindowMs: Int64 = 120_000
    static let maxDecodeWorkers = 8
    /// A changed Antigravity database is read at most this often; its WAL is written continuously (METRICS 5.4).
    static let databaseReadIntervalNs: UInt64 = 500_000_000
    /// Database connections unused this long are closed, and at most `maxOpenDatabases` stay open (METRICS 5.4).
    static let databaseIdleNs: UInt64 = 60_000_000_000
    static let maxOpenDatabases = 16
    /// Deduplication owner of every OpenCode row; transcript files count up from 0.
    static let opencodeFileID: FileID = -1
    static let zcodeFileID: FileID = -2

    let enabledSources: Set<SourceKind>
    let limits: ReadingLimits
    private(set) var roots: [Root]
    private var files: [String: TrackedFile] = [:]
    /// Incremental directory walks, by root path.
    private var indexes: [String: DirectoryIndex] = [:]
    private var deduper = Deduper()
    private var engine = SpeedEngine()
    private var parentMembers: [String: AgentParents.Member] = [:]
    private var parentLinks: [String: String] = [:]
    private var parentLinksAreStale = false
    private var nextFileID: FileID = 0
    private var pendingEvents: [SpeedEvent] = []
    private var unreadablePaths: Set<String> = []
    private var removedMalformedLines = 0
    private(set) var partialHistory = false
    /// The OpenCode database, when that source is enabled (METRICS 4.5, 5.2).
    let opencode: OpencodeSource?
    let zcode: ZcodeSource?
    private let zcodeRoot: String
    private var zcodeNeedsSeed = false
    private var zcodeLinks: [String: String] = [:]
    private let opencodeRoot: String
    private var opencodeNeedsSeed = false
    private var opencodeLinks: [String: String] = [:]

    /// Wall-clock milliseconds, for the age rule of completion events (METRICS 6.4); tests pin it.
    private let clock: @Sendable () -> Int64
    /// When set, live whole-file reads are handed here instead of running on the session queue; the owner performs
    /// them and returns the result through `completeWholeFileRead`. Without it they run inline.
    var wholeFileReads: ((WholeFileRead) -> Void)?

    init(
        configuration: MonitorConfiguration,
        limits: ReadingLimits = .standard,
        pricing: PriceBook? = nil,
        clock: @escaping @Sendable () -> Int64 = { Clock.milliseconds(Date()) }
    ) {
        enabledSources = configuration.enabledSources
        self.limits = limits
        self.clock = clock
        engine = SpeedEngine(pricing: pricing)
        roots = TranscriptFamily.allCases.flatMap { family in
            configuration.resolvedRoots(for: family).map { path in
                Root(family: family, path: path, canonicalPath: path, enabled: configuration.reads(family), available: false,
                     readable: MonitorConfiguration.isReadable(root: path, family: family),
                     detectionPath: family.isWorkBuddy ? TranscriptLocations.workbuddyDataFolder(ofRoot: path) : nil)
            }
        }
        opencodeRoot = configuration.resolvedOpencodeRoot
        opencode = configuration.readsOpencode ? OpencodeSource(root: opencodeRoot, fileID: Self.opencodeFileID) : nil
        zcodeRoot = configuration.resolvedZcodeRoot
        zcode = configuration.readsZcode ? ZcodeSource(root: zcodeRoot, fileID: Self.zcodeFileID) : nil
        refreshAvailability()
    }

    // MARK: - Roots

    var hasAvailableRoot: Bool { roots.contains { $0.enabled && $0.detected } || opencode?.isReady == true || zcode?.isReady == true }

    var watchedPaths: [String] {
        var paths = roots.filter { $0.enabled && $0.available }.map(\.canonicalPath)
        if let directory = opencode?.watchedDirectory, opencode?.isReady == true, !paths.contains(directory) {
            paths.append(directory)
        }
        if let directory = zcode?.watchedDirectory, !paths.contains(directory) { paths.append(directory) }
        return paths
    }

    var zcodeLocation: (path: String, available: Bool) { (zcodeRoot, zcode?.exists ?? false) }

    /// Root path and availability of the OpenCode source (the folder that contains `opencode.db`).
    var opencodeLocation: (path: String, available: Bool, status: OpencodeSource.Status?) {
        (opencodeRoot, opencode?.exists ?? false, opencode?.status)
    }

    /// Re-checks which roots exist. Returns true when availability changed.
    @discardableResult
    func refreshAvailability() -> Bool {
        var changed = false
        if let opencode, opencode.refreshAvailability() {
            changed = true
            opencodeNeedsSeed = true
        }
        if let zcode, zcode.refreshAvailability() {
            changed = true
            zcodeNeedsSeed = true
        }
        for index in roots.indices {
            let available = roots[index].readable && TranscriptDiscovery.isAvailable(root: roots[index].path)
            let detected = available || roots[index].detectionPath.map(TranscriptDiscovery.isAvailable(root:)) == true
            if available != roots[index].available || detected != roots[index].detected { changed = true }
            roots[index].available = available
            roots[index].detected = detected
            if available, let resolved = realpath(roots[index].path, nil) {
                roots[index].canonicalPath = String(cString: resolved)
                free(resolved)
            }
        }
        return changed
    }

    /// The family's first detected root, else its first root (Gemini CLI, omp and Antigravity can have several).
    func root(for family: TranscriptFamily) -> Root {
        roots.first { $0.family == family && $0.detected } ?? roots.first { $0.family == family }!
    }

    // MARK: - Seeding

    /// Reads the startup backlog (METRICS 5). Responses are seeded: they never produce live events.
    func seed(
        todayStartMs: Int64,
        progress: @Sendable (Double) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> SeedSummary {
        let started = DispatchTime.now().uptimeNanoseconds
        var summary = SeedSummary()
        refreshAvailability()

        var backlog: [(file: DiscoveredFile, tracked: TrackedFile)] = []
        let threshold = todayStartMs - Self.startupLookbackMs
        for root in roots where root.enabled && root.available {
            let discovered = TranscriptDiscovery.files(at: scan(root), family: root.family)
            for file in TranscriptDiscovery.mostRecent(discovered) where files[file.path] == nil {
                summary.filesDiscovered += 1
                var readsBacklog = file.stat.modifiedMs >= threshold
                let start: FileTailer.Start
                if !readsBacklog {
                    start = .end(file.stat.size)
                } else if root.family.isDatabase {
                    // A conversation database is read completely; the size rules of section 5 do not apply.
                    start = .beginning
                } else if TranscriptReader.isDocument(file.path), file.stat.size > DocumentReader.defaultMaxBytes {
                    // Whole-document sessions this large are not read at all (METRICS 4.6).
                    partialHistory = true
                    start = .end(file.stat.size)
                    readsBacklog = false
                } else if file.stat.size > limits.largeFileBytes, !TranscriptReader.isCompressedStream(file.path) {
                    // Compressed sessions are always read whole (METRICS 5.3).
                    partialHistory = true
                    if TranscriptReader.isFrameStream(file.path) {
                        // A frame stream cannot be entered in the middle, so it is not seeded at all (METRICS 5.1).
                        start = .end(file.stat.size)
                        readsBacklog = false
                    } else {
                        start = .tail(limits.tailWindowBytes)
                    }
                } else {
                    start = .beginning
                }
                let tracked = track(file, family: root.family, root: root.path, start: start)
                if readsBacklog { backlog.append((file, tracked)) }
            }
        }
        backlog.sort { TranscriptDiscovery.startupOrder($0.file, $1.file) }
        let ordered = backlog.map(\.tracked)

        let jobs = ordered.map { DecodeJob(family: $0.family, reader: $0.reader, size: $0.lastStat.size) }
        let decoded = Self.decodeInParallel(jobs, progress: progress, isCancelled: isCancelled)
        let seededAt = DispatchTime.now().uptimeNanoseconds
        for (file, result) in zip(ordered, decoded) {
            guard let result else { continue }
            file.reader = result.reader
            if file.family.isDatabase { file.lastReadNs = seededAt }
            summary.filesRead += 1
            summary.bytesRead += Int64(result.read.bytesRead)
            if result.read.didReset { file.resetParser() }
            var upserts: [ResponseUpsert] = []
            file.parser.consume(result.lines, deduper: &deduper) { upserts.append($0) }
            let project = projectName(of: file)
            for upsert in upserts { deliver(upsert, project: project, live: false) }
            finishRead(of: file, result: result.read)
        }
        closeIdleDatabases(nowNs: seededAt)
        if let opencode, opencode.exists {
            summary.filesDiscovered += 1
            if opencode.isReady {
                summary.filesRead += 1
                summary.bytesRead += opencode.databaseSize
            }
            seedOpencode(todayStartMs: todayStartMs)
        }
        if let zcode, zcode.exists {
            summary.filesDiscovered += 1
            if zcode.isReady {
                summary.filesRead += 1
                summary.bytesRead += zcode.databaseSize
            }
            zcodeNeedsSeed = false
            apply(zcode.seed(todayStartMs: todayStartMs, deduper: &deduper), live: false)
        }
        summary.partialHistory = partialHistory
        summary.durationMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return summary
    }

    private struct DecodeJob: Sendable {
        var family: TranscriptFamily
        var reader: TranscriptReader
        var size: Int64
    }

    private struct DecodedFile: Sendable {
        var reader: TranscriptReader
        var lines: DecodedLines
        var read: FileTailer.ReadResult
    }

    private struct DecodeProgress: Sendable {
        var next = 0
        var bytes: Int64 = 0
        var results: [DecodedFile?]
    }

    /// Reads and decodes files concurrently; each job is handled by exactly one worker.
    private static func decodeInParallel(
        _ jobs: [DecodeJob],
        progress: @Sendable (Double) -> Void,
        isCancelled: @Sendable () -> Bool
    ) -> [DecodedFile?] {
        guard !jobs.isEmpty else { return [] }
        let schedule = jobs.indices.sorted { jobs[$0].size > jobs[$1].size }
        let totalBytes = max(1, jobs.reduce(Int64(0)) { $0 + $1.size })
        let state = OSAllocatedUnfairLock(initialState: DecodeProgress(results: Array(repeating: nil, count: jobs.count)))
        let workers = min(jobs.count, max(1, min(ProcessInfo.processInfo.activeProcessorCount, maxDecodeWorkers)))

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while !isCancelled() {
                let slot = state.withLock { progress -> Int in
                    defer { progress.next += 1 }
                    return progress.next
                }
                guard slot < schedule.count else { return }
                let index = schedule[slot]
                var job = jobs[index]
                let decoded = decode(&job)
                let size = job.size
                let done = state.withLock { progress -> Int64 in
                    progress.results[index] = decoded
                    progress.bytes += size
                    return progress.bytes
                }
                progress(min(1, Double(done) / Double(totalBytes)))
            }
        }
        return state.withLock { $0.results }
    }

    private static func decode(_ job: inout DecodeJob) -> DecodedFile {
        let (lines, read) = TranscriptDecoder.decode(job.family, reader: &job.reader)
        return DecodedFile(reader: job.reader, lines: lines, read: read)
    }

    // MARK: - Live reading

    /// Reads files reported by the watcher. Unknown transcript paths under a root become new agents.
    @discardableResult
    func handleChanges(atCanonicalPaths paths: Set<String>) -> Bool {
        var changed = false
        if let opencode, paths.contains(where: opencode.matches(canonicalPath:)) {
            changed = apply(opencode.refresh(deduper: &deduper), live: true)
        }
        if let zcode, paths.contains(where: zcode.matches(canonicalPath:)) {
            changed = apply(zcode.refresh(deduper: &deduper), live: true) || changed
        }
        var handled: Set<String> = []
        for path in paths.sorted() {
            guard let (localPath, root) = localPath(forCanonical: path), handled.insert(localPath).inserted else { continue }
            if let file = files[localPath] {
                changed = read(file, live: true) || changed
            } else if let stat = root.family.stat(localPath) {
                let file = track(DiscoveredFile(path: localPath, stat: stat), family: root.family, root: root.path, start: .beginning)
                changed = read(file, live: true) || changed
            }
        }
        return changed
    }

    /// Reads the databases whose changes arrived while their reads were throttled (METRICS 5.4).
    @discardableResult
    func readDirtyDatabases() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        var changed = false
        for file in files.values.filter(\.isDirty).sorted(by: { $0.path < $1.path })
        where now &- file.lastReadNs >= Self.databaseReadIntervalNs {
            changed = read(file, live: true) || changed
        }
        return changed
    }

    /// Closes database connections idle for a minute, then the least recently changed beyond the limit.
    private func closeIdleDatabases(nowNs: UInt64) {
        var open = files.values.filter { $0.family.isDatabase && !$0.wholeReadInFlight && $0.reader.hasOpenConnection }
        guard !open.isEmpty else { return }
        for file in open where nowNs &- file.lastReadNs >= Self.databaseIdleNs { file.reader.closeConnection() }
        open = open.filter { $0.reader.hasOpenConnection }
        guard open.count > Self.maxOpenDatabases else { return }
        open.sort { $0.lastStat.modifiedNs != $1.lastStat.modifiedNs ? $0.lastStat.modifiedNs < $1.lastStat.modifiedNs : $0.path < $1.path }
        for file in open.prefix(open.count - Self.maxOpenDatabases) { file.reader.closeConnection() }
    }

    /// The 1-second fallback: stat files modified in the last two minutes.
    @discardableResult
    func pollRecentFiles(nowMs: Int64) -> Bool {
        var changed = false
        if let update = opencode?.refreshIfChanged(deduper: &deduper) {
            changed = apply(update, live: true)
        }
        if let update = zcode?.refreshIfChanged(deduper: &deduper) { changed = apply(update, live: true) || changed }
        let hot = files.values.filter { nowMs - $0.lastStat.modifiedMs <= Self.hotWindowMs }
        for file in hot.sorted(by: { $0.path < $1.path }) {
            guard let stat = file.family.stat(file.path) else {
                untrack(file.path)
                changed = true
                continue
            }
            if file.hasChanged(comparedTo: stat) { changed = read(file, live: true) || changed }
        }
        changed = readDirtyDatabases() || changed
        closeIdleDatabases(nowNs: DispatchTime.now().uptimeNanoseconds)
        return changed
    }

    /// Full rediscovery: new files are read from offset 0, vanished files are dropped, and files active today are
    /// re-checked in case the watcher missed a change.
    @discardableResult
    func rediscover(todayStartMs: Int64) -> Bool {
        var changed = refreshAvailability()
        var seen: Set<String> = []
        var fresh: [(DiscoveredFile, Root)] = []
        let activeSince = todayStartMs - Self.startupLookbackMs
        for root in roots where root.enabled && root.available {
            for path in boundedCandidates(root) where seen.insert(path).inserted {
                if let file = files[path] {
                    guard file.lastStat.modifiedMs >= activeSince, let stat = root.family.stat(path) else { continue }
                    if file.hasChanged(comparedTo: stat) { changed = read(file, live: true) || changed }
                } else if let stat = root.family.stat(path) {
                    fresh.append((DiscoveredFile(path: path, stat: stat), root))
                }
            }
        }
        for path in files.keys where !seen.contains(path) {
            untrack(path)
            changed = true
        }
        fresh.sort { TranscriptDiscovery.startupOrder($0.0, $1.0) }
        for (discovered, root) in fresh {
            let file = track(discovered, family: root.family, root: root.path, start: .beginning)
            changed = read(file, live: true) || changed
        }
        for file in files.values where file.family == .grokBuild {
            var upserts: [ResponseUpsert] = []
            if file.parser.refreshMetadata(deduper: &deduper, emit: { upserts.append($0) }) {
                for upsert in upserts { deliver(upsert, project: projectName(of: file), live: true) }
                syncAgent(file)
                changed = true
            }
        }
        if let opencode {
            if opencodeNeedsSeed {
                seedOpencode(todayStartMs: todayStartMs)
                changed = true
            } else {
                changed = apply(opencode.rediscover(nowMs: clock(), deduper: &deduper), live: true) || changed
            }
        }
        if let zcode {
            if zcodeNeedsSeed {
                zcodeNeedsSeed = false
                changed = apply(zcode.seed(todayStartMs: todayStartMs, deduper: &deduper), live: false) || changed
            } else if let update = zcode.refreshIfChanged(deduper: &deduper) {
                changed = apply(update, live: true) || changed
            }
        }
        return changed
    }

    /// Candidate paths of a root, limited to the most recently modified ones when there are too many.
    private func boundedCandidates(_ root: Root) -> [String] {
        let candidates = scan(root)
        guard candidates.count > TranscriptDiscovery.maxFiles else { return candidates }
        let ranked = candidates.compactMap { path -> DiscoveredFile? in
            if let file = files[path] { return DiscoveredFile(path: path, stat: file.lastStat) }
            guard let stat = root.family.stat(path) else { return nil }
            return DiscoveredFile(path: path, stat: stat)
        }
        return TranscriptDiscovery.mostRecent(ranked).map(\.path)
    }

    private func scan(_ root: Root) -> [String] {
        var index = indexes[root.path] ?? DirectoryIndex(root: root.path, names: root.family.names)
        let paths = index.scan()
        indexes[root.path] = index
        return paths
    }

    @discardableResult
    private func read(_ file: TrackedFile, live: Bool) -> Bool {
        if live, let schedule = wholeFileReads, file.reader.readsWholeFile {
            guard !file.wholeReadInFlight else {
                file.wholeReadAgain = true
                return false
            }
            file.wholeReadInFlight = true
            file.isDirty = false
            if let stat = file.family.stat(file.path) { file.lastStat = stat }
            schedule(WholeFileRead(path: file.path, family: file.family, fileID: file.fileID, reader: file.reader))
            return false
        }
        if file.family.isDatabase { return readDatabase(file, live: live) }
        var upserts: [ResponseUpsert] = []
        let metadataChanged = file.parser.refreshMetadata(deduper: &deduper) { upserts.append($0) }
        for upsert in upserts { deliver(upsert, project: projectName(of: file), live: live) }
        upserts.removeAll(keepingCapacity: true)
        let result = file.reader.read(onReset: { file.resetParser() }, onMalformed: { file.parser.noteMalformedLine() }) { bytes in
            file.parser.consume(rawLine: bytes, deduper: &deduper) { upserts.append($0) }
            guard !upserts.isEmpty else { return }
            let project = projectName(of: file)
            for upsert in upserts { deliver(upsert, project: project, live: live) }
            upserts.removeAll(keepingCapacity: true)
        }
        if result.failed, FileStat.lstat(file.path) == nil {
            untrack(file.path)
            return true
        }
        finishRead(of: file, result: result)
        return metadataChanged || result.bytesRead > 0 || result.didReset
    }

    /// One read of an Antigravity database, throttled while live (METRICS 5.4).
    private func readDatabase(_ file: TrackedFile, live: Bool) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if live, file.lastReadNs != 0, now &- file.lastReadNs < Self.databaseReadIntervalNs {
            file.isDirty = true
            return false
        }
        file.isDirty = false
        file.lastReadNs = now
        let (batch, result) = file.reader.readDatabase()
        if result.failed, file.family.stat(file.path) == nil {
            untrack(file.path)
            return true
        }
        if result.didReset { file.resetParser() }
        var upserts: [ResponseUpsert] = []
        file.parser.consume(.antigravity(batch), deduper: &deduper) { upserts.append($0) }
        let project = projectName(of: file)
        for upsert in upserts { deliver(upsert, project: project, live: live) }
        finishRead(of: file, result: result)
        return result.bytesRead > 0 || result.didReset
    }

    /// Applies a whole-file read in one step. A key another file emitted first in the meantime stays that file's.
    /// Returns true when anything changed.
    @discardableResult
    func completeWholeFileRead(_ result: WholeFileResult) -> Bool {
        guard let file = files[result.path], file.fileID == result.fileID else { return false }
        file.wholeReadInFlight = false
        file.reader = result.reader
        if file.family.isDatabase { file.lastReadNs = DispatchTime.now().uptimeNanoseconds }
        if result.read.failed, file.family.stat(file.path) == nil {
            untrack(file.path)
            return true
        }
        if result.read.didReset { file.resetParser() }
        var upserts: [ResponseUpsert] = []
        file.parser.consume(result.lines, deduper: &deduper) { upserts.append($0) }
        let project = projectName(of: file)
        for upsert in upserts { deliver(upsert, project: project, live: true) }
        finishRead(of: file, result: result.read)
        if file.wholeReadAgain {
            file.wholeReadAgain = false
            read(file, live: true)
        }
        return result.read.bytesRead > 0 || result.read.didReset
    }

    private func finishRead(of file: TrackedFile, result: FileTailer.ReadResult) {
        if result.oversized || file.parser.hasPartialHistory { partialHistory = true }
        if result.failed {
            unreadablePaths.insert(file.path)
        } else {
            unreadablePaths.remove(file.path)
        }
        if file.family == .grokBuild, let stat = file.family.stat(file.path) {
            file.lastStat = stat
        } else if let stat = result.stat {
            file.lastStat = stat
        }
        syncAgent(file)
    }

    // MARK: - Engine

    func advance(
        nowMs: Int64,
        todayStartMs: Int64,
        emitsEvents: Bool,
        subsets: Set<SourceSet> = []
    ) -> (output: EngineOutput, events: [SpeedEvent]) {
        if parentLinksAreStale {
            parentLinks = AgentParents.resolve(Array(parentMembers.values), direct: opencodeLinks.merging(zcodeLinks) { first, _ in first })
            engine.setParents(parentLinks)
            parentLinksAreStale = false
        }
        let output = engine.advance(nowMs: nowMs, todayStartMs: todayStartMs, emitsEvents: emitsEvents, subsets: subsets)
        let events = pendingEvents + output.events
        pendingEvents.removeAll()
        return (output, events)
    }

    /// Responses currently held by the engine.
    var responses: [ResponseRecord] { engine.storedResponses }

    var malformedLines: Int {
        files.values.reduce(removedMalformedLines) { $0 + $1.parser.state.malformedLines } + (opencode?.malformedRows ?? 0)
    }

    var unreadableFileCount: Int { unreadablePaths.count + (opencode?.status == .unreadable ? 1 : 0) + (zcode?.status == .unreadable ? 1 : 0) }

    /// Antigravity databases whose connection is open.
    var openDatabaseCount: Int {
        files.values.filter { $0.family.isDatabase && $0.reader.hasOpenConnection }.count
    }

    /// Sources with data this version cannot read: OpenCode, or an Antigravity database without its tables.
    var unsupportedSources: [SourceKind] {
        var sources: [SourceKind] = []
        if opencode?.status == .unsupported { sources.append(.opencode) }
        if zcode?.status == .unsupported { sources.append(.zcode) }
        if enabledSources.contains(.antigravity), files.values.contains(where: { $0.family.isDatabase && $0.parser.isUnsupported }) {
            sources.append(.antigravity)
        }
        return sources
    }

    /// Agents of each source with at least one line today; WorkBuddy counts main sessions only (DESIGN 5).
    func sessionCounts(todayStartMs: Int64) -> [SourceKind: Int] {
        var counts: [SourceKind: Int] = [:]
        for file in files.values {
            let state = file.parser.state
            guard let last = state.lastLineMs, last >= todayStartMs, enabledSources.contains(state.source) else { continue }
            if (file.family.isWorkBuddy || file.family == .kimi || file.family == .grokBuild), state.isSubagent { continue }
            counts[state.source, default: 0] += 1
        }
        if let opencode, enabledSources.contains(.opencode) {
            counts[.opencode] = opencode.activeSessionCount(todayStartMs: todayStartMs)
        }
        if let zcode { counts[.zcode] = zcode.activeSessionCount(todayStartMs: todayStartMs) }
        return counts
    }

    private func deliver(_ upsert: ResponseUpsert, project: String, live: Bool) {
        guard enabledSources.contains(upsert.record.source) else { return }
        let nowMs = live ? clock() : nil
        if let event = engine.upsert(upsert.record, project: project, isCompletion: upsert.isCompletion, emitsEvents: live, nowMs: nowMs) {
            pendingEvents.append(event)
        }
    }

    private func syncAgent(_ file: TrackedFile) {
        let state = file.parser.state
        if state.lastLineMs != nil, enabledSources.contains(state.source) {
            let member = AgentParents.Member(id: file.path, family: file.family, thread: state.thread)
            if parentMembers.updateValue(member, forKey: file.path) != member { parentLinksAreStale = true }
            engine.setAgent(EngineAgent(id: file.path, state: state, parentId: parentLinks[file.path]))
        } else {
            removeAgent(file.path)
        }
    }

    private func removeAgent(_ path: String) {
        if parentMembers.removeValue(forKey: path) != nil { parentLinksAreStale = true }
        engine.removeAgent(id: path)
    }

    private func projectName(of file: TrackedFile) -> String {
        file.parser.state.project ?? EngineAgent.fallbackProject(for: file.path)
    }

    // MARK: - OpenCode

    private func seedOpencode(todayStartMs: Int64) {
        guard let opencode else { return }
        opencodeNeedsSeed = false
        apply(opencode.seed(todayStartMs: todayStartMs, deduper: &deduper), live: false)
    }

    @discardableResult
    private func apply(_ update: OpencodeSource.Update, live: Bool) -> Bool {
        guard !update.isEmpty else { return false }
        for (upsert, project) in update.upserts { deliver(upsert, project: project, live: live) }
        for id in update.removedAgents { engine.removeAgent(id: id) }
        for (id, state) in update.agents {
            if state.lastLineMs != nil {
                engine.setAgent(EngineAgent(id: id, state: state, parentId: parentLinks[id]))
            } else {
                engine.removeAgent(id: id)
            }
        }
        let links = opencode?.parentLinks ?? [:]
        if links != opencodeLinks {
            opencodeLinks = links
            parentLinksAreStale = true
        }
        return true
    }

    @discardableResult
    private func apply(_ update: ZcodeSource.Update, live: Bool) -> Bool {
        for (upsert, project) in update.upserts { deliver(upsert, project: project, live: live) }
        for id in update.removedAgents { engine.removeAgent(id: id) }
        for (id, state) in update.agents {
            if state.lastLineMs != nil { engine.setAgent(EngineAgent(id: id, state: state, parentId: zcode?.parentLinks[id])) }
        }
        let links = zcode?.parentLinks ?? [:]
        if links != zcodeLinks {
            zcodeLinks = links
            parentLinksAreStale = true
        }
        return !update.isEmpty
    }

    // MARK: - Tracking

    private func track(_ file: DiscoveredFile, family: TranscriptFamily, root: String, start: FileTailer.Start) -> TrackedFile {
        let tracked = TrackedFile(
            path: file.path, family: family, root: root, fileID: nextFileID, stat: file.stat, start: start,
            maxLineBytes: limits.maxLineBytes
        )
        nextFileID &+= 1
        files[file.path] = tracked
        return tracked
    }

    private func untrack(_ path: String) {
        guard let file = files.removeValue(forKey: path) else { return }
        removedMalformedLines += file.parser.state.malformedLines
        unreadablePaths.remove(path)
        removeAgent(path)
    }

    /// Maps an FSEvents (canonical) path to the configured-root path, if it names a candidate transcript (an
    /// Antigravity `-wal` names its database).
    private func localPath(forCanonical changed: String) -> (String, Root)? {
        for root in roots where root.enabled && root.available {
            let path = root.family.transcriptPath(forChanged: changed)
            guard root.family.names.matches((path as NSString).lastPathComponent) else { continue }
            let prefix = root.canonicalPath == "/" ? "/" : root.canonicalPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = path.dropFirst(prefix.count)
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty, root.family.names.accepts(relativeComponents: components),
                  !relative.contains("/../") else { return nil }
            let localPrefix = root.path == "/" ? "/" : root.path + "/"
            return (localPrefix + relative, root)
        }
        return nil
    }
}
