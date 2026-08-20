import Foundation

enum RunningThreadScanner {
    static let defaultLivenessLease: TimeInterval = 24 * 60 * 60

    private static let readChunkSize = 256 * 1024
    private static let maximumLifecycleLineBytes = 2 * 1024 * 1024
    private static let maximumLifecyclePrefixBytes = 64 * 1024
    private static let successfulDatabaseCandidateTTL: TimeInterval = 10
    private static let databaseCandidateCache = DatabaseCandidateCache()

    private struct DatabaseIdentity: Equatable {
        let deviceID: UInt64
        let fileID: UInt64
    }

    private final class DatabaseCandidateCache: @unchecked Sendable {
        private struct Entry {
            let identity: DatabaseIdentity
            let checkedAt: Date
            let paths: Set<String>
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func value(
            for key: String,
            identity: DatabaseIdentity,
            now: Date,
            maximumAge: TimeInterval
        ) -> Set<String>? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key],
                  entry.identity == identity,
                  now.timeIntervalSince(entry.checkedAt) >= 0,
                  now.timeIntervalSince(entry.checkedAt) < maximumAge else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.paths
        }

        func store(
            _ paths: Set<String>,
            for key: String,
            identity: DatabaseIdentity,
            now: Date
        ) {
            lock.lock()
            entries[key] = Entry(identity: identity, checkedAt: now, paths: paths)
            lock.unlock()
        }
    }

    private struct FileFingerprint {
        let deviceID: UInt64?
        let fileID: UInt64?
        let size: UInt64
        let modifiedAt: Date
    }

    private struct SessionMetadata {
        let id: String
        let isSubagent: Bool
    }

    private struct LifecycleEvent {
        let lifecycle: RunningThreadLifecycle
        let timestamp: Date?
    }

    private struct CanonicalSource {
        let home: URL
        let sessions: URL
    }

    private enum ScanError: Error {
        case sourceIdentityChanged
        case sessionsRootInvalid
        case fileReadFailed
        case sessionMetadataMissing
    }

    static func scan(
        dataSource: CodexDataSource,
        previousStates: [String: RunningThreadFileState],
        now: Date,
        livenessLease: TimeInterval = defaultLivenessLease,
        fileManager: FileManager = .default
    ) -> RunningThreadScanResult? {
        let safeLease = livenessLease.isFinite && livenessLease > 0
            ? livenessLease
            : defaultLivenessLease
        let cutoff = now.addingTimeInterval(-safeLease)

        do {
            guard fileManager.fileExists(atPath: dataSource.sessionsRoot.path) else {
                return RunningThreadScanResult(
                    states: [:],
                    summary: RunningThreadSummary(
                        main: 0,
                        subagents: 0,
                        updatedAt: now,
                        freshness: .fresh
                    )
                )
            }

            let canonicalSource = try canonicalSource(
                dataSource: dataSource,
                fileManager: fileManager
            )
            let files = try candidateFiles(
                dataSource: dataSource,
                canonicalSource: canonicalSource,
                cutoff: cutoff,
                now: now,
                previousStates: previousStates,
                fileManager: fileManager
            )
            var states: [String: RunningThreadFileState] = [:]
            var hadFileReadFailure = false

            for file in files {
                if Task.isCancelled {
                    return nil
                }
                let path = file.path
                do {
                    states[path] = try scanFile(
                        file,
                        previousState: previousStates[path],
                        fileManager: fileManager
                    )
                } catch {
                    hadFileReadFailure = true
                    if let previous = previousStates[path],
                       previous.modifiedAt >= cutoff {
                        states[path] = previous
                    }
                }
            }
            if hadFileReadFailure {
                return nil
            }
            if let expectedIdentity = dataSource.homeIdentity,
               CodexHomeIdentity.read(
                   at: dataSource.codexHome,
                   fileManager: fileManager
               ) != expectedIdentity {
                return nil
            }

            return RunningThreadScanResult(
                states: states,
                summary: summary(states: states, cutoff: cutoff, now: now)
            )
        } catch {
            return nil
        }
    }

    private static func canonicalSource(
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> CanonicalSource {
        if let expectedIdentity = dataSource.homeIdentity,
           CodexHomeIdentity.read(at: dataSource.codexHome, fileManager: fileManager) != expectedIdentity {
            throw ScanError.sourceIdentityChanged
        }

        let home = dataSource.codexHome.standardizedFileURL
        let homeValues = try home.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard homeValues.isDirectory == true,
              homeValues.isSymbolicLink != true else {
            throw ScanError.sessionsRootInvalid
        }
        let canonicalHome = home.resolvingSymlinksInPath()
        let root = dataSource.sessionsRoot.standardizedFileURL
        let values = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ScanError.sessionsRootInvalid
        }
        let canonicalSessions = root.resolvingSymlinksInPath()
        guard isContained(canonicalSessions, in: canonicalHome) else {
            throw ScanError.sessionsRootInvalid
        }
        return CanonicalSource(home: canonicalHome, sessions: canonicalSessions)
    }

    private static func candidateFiles(
        dataSource: CodexDataSource,
        canonicalSource: CanonicalSource,
        cutoff: Date,
        now: Date,
        previousStates: [String: RunningThreadFileState],
        fileManager: FileManager
    ) throws -> [URL] {
        let databasePaths: Set<String>?
        do {
            databasePaths = try databaseCandidatePaths(
                dataSource: dataSource,
                cutoff: cutoff,
                now: now,
                fileManager: fileManager
            )
        } catch {
            databasePaths = nil
        }
        var rawPaths: Set<String>
        if let databasePaths {
            rawPaths = databasePaths
            if previousStates.isEmpty || databasePaths.isEmpty {
                // The state database is an optimization, not the authority for
                // local session existence. A cold scan must also discover
                // recent JSONL files that have not reached SQLite yet.
                rawPaths.formUnion(
                    try fallbackCandidatePaths(
                        canonicalRoot: canonicalSource.sessions,
                        cutoff: cutoff,
                        fileManager: fileManager
                    )
                )
            } else {
                rawPaths.formUnion(
                    previousStates.compactMap { path, state in
                        state.modifiedAt >= cutoff ? path : nil
                    }
                )
            }
        } else {
            rawPaths = try fallbackCandidatePaths(
                canonicalRoot: canonicalSource.sessions,
                cutoff: cutoff,
                fileManager: fileManager
            )
        }

        var seen = Set<String>()
        var files: [URL] = []
        for path in rawPaths.sorted() {
            guard let file = trustedJSONLFile(
                path: path,
                canonicalSource: canonicalSource,
                fileManager: fileManager
            ) else {
                continue
            }
            if seen.insert(file.path).inserted {
                files.append(file)
            }
        }
        return files
    }

    private static func databaseCandidatePaths(
        dataSource: CodexDataSource,
        cutoff: Date,
        now: Date,
        fileManager: FileManager
    ) throws -> Set<String>? {
        let databaseURL = dataSource.stateDatabase
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: databaseURL.path)
        guard let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        let identity = DatabaseIdentity(deviceID: deviceID, fileID: fileID)
        let cacheKey = "\(dataSource.stableIdentityKey)|\(databaseURL.standardizedFileURL.path)"
        if let cached = databaseCandidateCache.value(
            for: cacheKey,
            identity: identity,
            now: now,
            maximumAge: successfulDatabaseCandidateTTL
        ) {
            return cached
        }

        let paths: Set<String>? = try SQLiteReadRecovery.run {
            try CodexStateDatabaseReadPool.shared.withConnection(
                url: databaseURL
            ) { connection in
                try connection.readTransaction { snapshot in
                    let columns = Set(
                        try snapshot.readRows("PRAGMA table_info(threads)") { statement in
                            statement.text(1) ?? ""
                        }
                    )
                    guard columns.contains("rollout_path"),
                          columns.contains("updated_at_ms") || columns.contains("updated_at") else {
                        return nil
                    }

                    let archivedExpression = columns.contains("archived")
                        ? "COALESCE(archived, 0)"
                        : "0"
                    let updatedExpression: String
                    if columns.contains("updated_at_ms"), columns.contains("updated_at") {
                        updatedExpression = """
                        CASE
                            WHEN COALESCE(updated_at_ms, 0) > 0 THEN updated_at_ms
                            ELSE COALESCE(updated_at, 0) * 1000
                        END
                        """
                    } else if columns.contains("updated_at_ms") {
                        updatedExpression = "COALESCE(updated_at_ms, 0)"
                    } else {
                        updatedExpression = "COALESCE(updated_at, 0) * 1000"
                    }

                    let rows = try snapshot.readRows(
                        """
                        SELECT rollout_path
                        FROM threads
                        WHERE \(archivedExpression) = 0
                          AND \(updatedExpression) >= ?
                        """,
                        bindings: [.int64(Int64(cutoff.timeIntervalSince1970 * 1000))]
                    ) { statement in
                        statement.text(0) ?? ""
                    }
                    return Set(rows.filter { !$0.isEmpty })
                }
            }
        }
        if let paths {
            databaseCandidateCache.store(
                paths,
                for: cacheKey,
                identity: identity,
                now: now
            )
        }
        return paths
    }

    private static func fallbackCandidatePaths(
        canonicalRoot: URL,
        cutoff: Date,
        fileManager: FileManager
    ) throws -> Set<String> {
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw ScanError.sessionsRootInvalid
        }

        var paths = Set<String>()
        for case let file as URL in enumerator {
            if Task.isCancelled {
                throw CancellationError()
            }
            let values = try file.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  file.pathExtension.lowercased() == "jsonl",
                  (values.contentModificationDate ?? .distantPast) >= cutoff else {
                continue
            }
            paths.insert(file.path)
        }
        if let traversalError {
            throw traversalError
        }
        return paths
    }

    private static func trustedJSONLFile(
        path: String,
        canonicalSource: CanonicalSource,
        fileManager: FileManager
    ) -> URL? {
        let expanded = NSString(string: path).expandingTildeInPath
        let candidate = (NSString(string: expanded).isAbsolutePath
            ? URL(fileURLWithPath: expanded)
            : canonicalSource.home.appendingPathComponent(expanded))
            .standardizedFileURL
        guard candidate.pathExtension.lowercased() == "jsonl",
              fileManager.fileExists(atPath: candidate.path),
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }

        let resolved = candidate.resolvingSymlinksInPath()
        guard isContained(resolved, in: canonicalSource.sessions),
              let resolvedValues = try? resolved.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              resolvedValues.isRegularFile == true,
              resolvedValues.isSymbolicLink != true else {
            return nil
        }
        return resolved
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func scanFile(
        _ file: URL,
        previousState: RunningThreadFileState?,
        fileManager: FileManager
    ) throws -> RunningThreadFileState {
        let fingerprint = try fingerprint(file: file, fileManager: fileManager)

        if var state = previousState,
           state.deviceID == fingerprint.deviceID,
           state.fileID == fingerprint.fileID,
           state.observedSize <= fingerprint.size,
           state.offset <= fingerprint.size,
           (
               state.observedSize < fingerprint.size
                   || state.modifiedAt == fingerprint.modifiedAt
           ),
           let currentBoundarySignature = try? boundarySignature(
               file: file,
               endOffset: state.offset
           ),
           state.boundarySignature == currentBoundarySignature {
            if state.offset < fingerprint.size {
                let parsed = try parseForward(
                    file: file,
                    from: state.offset,
                    through: fingerprint.size,
                    initialLifecycle: state.lifecycle,
                    initialTimestamp: state.lifecycleAt
                )
                state.offset = parsed.offset
                state.boundarySignature = try boundarySignature(
                    file: file,
                    endOffset: parsed.offset
                )
                state.lifecycle = parsed.lifecycle
                state.lifecycleAt = parsed.timestamp
            }
            state.observedSize = fingerprint.size
            state.modifiedAt = fingerprint.modifiedAt
            return state
        }

        let metadata = try firstLineMetadata(file: file)
        let completeEnd = try lastCompleteLineEnd(file: file, size: fingerprint.size)
        let lifecycle = try latestLifecycle(
            file: file,
            completeEnd: completeEnd
        )
        return RunningThreadFileState(
            deviceID: fingerprint.deviceID,
            fileID: fingerprint.fileID,
            offset: completeEnd,
            observedSize: fingerprint.size,
            boundarySignature: try boundarySignature(
                file: file,
                endOffset: completeEnd
            ),
            sessionID: metadata.id,
            isSubagent: metadata.isSubagent,
            lifecycle: lifecycle?.lifecycle ?? .unknown,
            lifecycleAt: lifecycle?.timestamp,
            modifiedAt: fingerprint.modifiedAt
        )
    }

    private static func fingerprint(
        file: URL,
        fileManager: FileManager
    ) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw ScanError.fileReadFailed
        }
        return FileFingerprint(
            deviceID: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    private static func firstLineMetadata(file: URL) throws -> SessionMetadata {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var line = Data()
        while line.count <= maximumLifecycleLineBytes {
            if Task.isCancelled {
                throw CancellationError()
            }
            let chunk = handle.readData(ofLength: readChunkSize)
            guard !chunk.isEmpty else {
                break
            }
            if let newline = chunk.firstIndex(of: 10) {
                line.append(chunk[..<newline])
                break
            }
            line.append(chunk)
        }

        guard line.count <= maximumLifecycleLineBytes,
              let object = jsonObject(line),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              !id.isEmpty else {
            throw ScanError.sessionMetadataMissing
        }
        let threadSource = (payload["thread_source"] as? String)
            ?? (payload["threadSource"] as? String)
            ?? ""
        return SessionMetadata(
            id: id,
            isSubagent: isSubagentMarker(threadSource)
                || sourceContainsSubagentNode(payload["source"])
        )
    }

    private static func lastCompleteLineEnd(file: URL, size: UInt64) throws -> UInt64 {
        guard size > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var cursor = size
        while cursor > 0 {
            if Task.isCancelled {
                throw CancellationError()
            }
            let start = cursor > UInt64(readChunkSize)
                ? cursor - UInt64(readChunkSize)
                : 0
            try handle.seek(toOffset: start)
            let data = handle.readData(ofLength: Int(cursor - start))
            guard data.count == Int(cursor - start) else {
                throw ScanError.fileReadFailed
            }
            if let newline = data.lastIndex(of: 10) {
                return start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
            }
            cursor = start
        }
        return 0
    }

    private static func boundarySignature(
        file: URL,
        endOffset: UInt64
    ) throws -> UInt64 {
        let sampleSize = min(endOffset, 128)
        guard sampleSize > 0 else {
            return 14_695_981_039_346_656_037
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: endOffset - sampleSize)
        let data = handle.readData(ofLength: Int(sampleSize))
        guard data.count == Int(sampleSize) else {
            throw ScanError.fileReadFailed
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func latestLifecycle(
        file: URL,
        completeEnd: UInt64
    ) throws -> LifecycleEvent? {
        guard completeEnd > 0 else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var cursor = completeEnd
        var suffix = Data()
        var discardingOversizedLine = false

        while cursor > 0 {
            if Task.isCancelled {
                throw CancellationError()
            }
            let start = cursor > UInt64(readChunkSize)
                ? cursor - UInt64(readChunkSize)
                : 0
            try handle.seek(toOffset: start)
            let data = handle.readData(ofLength: Int(cursor - start))
            guard data.count == Int(cursor - start) else {
                throw ScanError.fileReadFailed
            }
            let newlineIndices = data.indices.filter { data[$0] == 10 }

            guard let firstNewline = newlineIndices.first,
                  let lastNewline = newlineIndices.last else {
                prepend(
                    data,
                    to: &suffix,
                    discardingOversizedLine: &discardingOversizedLine
                )
                cursor = start
                continue
            }

            let trailingStart = data.index(after: lastNewline)
            if discardingOversizedLine {
                if let event = lifecycleEventFromPrefix(
                    joining: data[trailingStart...],
                    suffix: suffix
                ) {
                    return event
                }
            } else {
                if let event = lifecycleEvent(
                    joining: data[trailingStart...],
                    suffix: suffix
                ) {
                    return event
                }
            }
            discardingOversizedLine = false
            suffix.removeAll(keepingCapacity: true)

            if newlineIndices.count > 1 {
                for index in stride(from: newlineIndices.count - 1, through: 1, by: -1) {
                    let lineStart = data.index(after: newlineIndices[index - 1])
                    let lineEnd = newlineIndices[index]
                    if let event = lifecycleEvent(in: Data(data[lineStart..<lineEnd])) {
                        return event
                    }
                }
            }

            let prefix = data[..<firstNewline]
            if start == 0 {
                if let event = lifecycleEvent(in: Data(prefix)) {
                    return event
                }
            } else {
                suffix = Data(prefix)
                if suffix.count > maximumLifecycleLineBytes {
                    suffix.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
            }
            cursor = start
        }
        return nil
    }

    private static func prepend(
        _ prefix: Data,
        to suffix: inout Data,
        discardingOversizedLine: inout Bool
    ) {
        if discardingOversizedLine {
            var joined = Data()
            joined.reserveCapacity(
                min(maximumLifecyclePrefixBytes, prefix.count + suffix.count)
            )
            joined.append(prefix.prefix(maximumLifecyclePrefixBytes))
            if joined.count < maximumLifecyclePrefixBytes {
                joined.append(
                    suffix.prefix(maximumLifecyclePrefixBytes - joined.count)
                )
            }
            suffix = joined
            return
        }
        guard prefix.count + suffix.count <= maximumLifecycleLineBytes else {
            var preservedPrefix = Data()
            preservedPrefix.reserveCapacity(maximumLifecyclePrefixBytes)
            preservedPrefix.append(prefix.prefix(maximumLifecyclePrefixBytes))
            if preservedPrefix.count < maximumLifecyclePrefixBytes {
                preservedPrefix.append(
                    suffix.prefix(maximumLifecyclePrefixBytes - preservedPrefix.count)
                )
            }
            suffix = preservedPrefix
            discardingOversizedLine = true
            return
        }
        var joined = Data()
        joined.reserveCapacity(prefix.count + suffix.count)
        joined.append(prefix)
        joined.append(suffix)
        suffix = joined
    }

    private static func lifecycleEvent(
        joining prefix: Data.SubSequence,
        suffix: Data
    ) -> LifecycleEvent? {
        guard prefix.count + suffix.count <= maximumLifecycleLineBytes else {
            return nil
        }
        var line = Data()
        line.reserveCapacity(prefix.count + suffix.count)
        line.append(prefix)
        line.append(suffix)
        return lifecycleEvent(in: line)
    }

    private static func lifecycleEventFromPrefix(
        joining prefix: Data.SubSequence,
        suffix: Data
    ) -> LifecycleEvent? {
        var linePrefix = Data()
        linePrefix.reserveCapacity(
            min(maximumLifecyclePrefixBytes, prefix.count + suffix.count)
        )
        linePrefix.append(prefix.prefix(maximumLifecyclePrefixBytes))
        if linePrefix.count < maximumLifecyclePrefixBytes {
            linePrefix.append(
                suffix.prefix(maximumLifecyclePrefixBytes - linePrefix.count)
            )
        }
        return lifecycleEventFromPrefix(linePrefix)
    }

    private static func parseForward(
        file: URL,
        from offset: UInt64,
        through endOffset: UInt64,
        initialLifecycle: RunningThreadLifecycle,
        initialTimestamp: Date?
    ) throws -> (
        offset: UInt64,
        lifecycle: RunningThreadLifecycle,
        timestamp: Date?
    ) {
        guard endOffset >= offset else {
            throw ScanError.fileReadFailed
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var cursor = offset
        var lastCompleteOffset = offset
        var line = Data()
        var discardingOversizedLine = false
        var lifecycle = initialLifecycle
        var timestamp = initialTimestamp

        while cursor < endOffset {
            if Task.isCancelled {
                throw CancellationError()
            }
            let requested = Int(min(UInt64(readChunkSize), endOffset - cursor))
            let chunk = handle.readData(ofLength: requested)
            guard chunk.count == requested else {
                throw ScanError.fileReadFailed
            }

            for byte in chunk {
                cursor += 1
                if byte == 10 {
                    let event = discardingOversizedLine
                        ? lifecycleEventFromPrefix(line)
                        : lifecycleEvent(in: line)
                    if let event {
                        lifecycle = event.lifecycle
                        timestamp = event.timestamp
                    }
                    line.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                    lastCompleteOffset = cursor
                } else if !discardingOversizedLine {
                    if line.count < maximumLifecycleLineBytes {
                        line.append(byte)
                    } else {
                        discardingOversizedLine = true
                    }
                }
            }
        }
        return (lastCompleteOffset, lifecycle, timestamp)
    }

    private static func lifecycleEvent(in line: Data) -> LifecycleEvent? {
        guard !line.isEmpty, line.count <= maximumLifecycleLineBytes else {
            return nil
        }
        let text = String(decoding: line, as: UTF8.self)
        guard text.contains("task_started")
            || text.contains("task_complete")
            || text.contains("turn_aborted")
            || text.contains("thread_rolled_back") else {
            return nil
        }
        guard let object = jsonObject(line),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        let lifecycle: RunningThreadLifecycle
        switch type {
        case "task_started":
            lifecycle = .running
        case "task_complete", "turn_aborted", "thread_rolled_back":
            lifecycle = .idle
        default:
            return nil
        }
        let numericTimestamp: TimeInterval?
        switch lifecycle {
        case .running:
            numericTimestamp = number(payload["started_at"])
        case .idle:
            numericTimestamp = number(payload["completed_at"])
                ?? number(payload["started_at"])
        case .unknown:
            numericTimestamp = nil
        }
        let timestamp = iso8601Date(object["timestamp"] as? String)
            ?? numericTimestamp.map(Date.init(timeIntervalSince1970:))
        return LifecycleEvent(lifecycle: lifecycle, timestamp: timestamp)
    }

    private static func lifecycleEventFromPrefix(_ line: Data) -> LifecycleEvent? {
        guard !line.isEmpty else { return nil }
        let text = String(decoding: line.prefix(maximumLifecyclePrefixBytes), as: UTF8.self)
        guard let payloadRange = text.range(of: "\"payload\"") else {
            return nil
        }
        let payloadPrefix = text[payloadRange.lowerBound...].prefix(4_096)
        guard let payloadType = firstJSONTypeValue(in: payloadPrefix) else {
            return nil
        }
        let lifecycle: RunningThreadLifecycle
        if payloadType == "task_started" {
            lifecycle = .running
        } else if payloadType == "task_complete"
            || payloadType == "turn_aborted"
            || payloadType == "thread_rolled_back" {
            lifecycle = .idle
        } else {
            return nil
        }
        let timestampPrefix = text[..<payloadRange.lowerBound]
        return LifecycleEvent(
            lifecycle: lifecycle,
            timestamp: iso8601Date(
                firstJSONStringValue(for: "timestamp", in: timestampPrefix)
            )
        )
    }

    private static func firstJSONTypeValue(
        in text: Substring
    ) -> String? {
        firstJSONStringValue(for: "type", in: text)
    }

    private static func firstJSONStringValue(
        for key: String,
        in text: Substring
    ) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let colon = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        let afterColon = text[text.index(after: colon)...]
            .drop { $0.isWhitespace }
        guard afterColon.first == "\"",
              let closingQuote = afterColon.dropFirst().firstIndex(of: "\"") else {
            return nil
        }
        return String(afterColon[afterColon.index(after: afterColon.startIndex)..<closingQuote])
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber,
              !(value is Bool) else {
            return nil
        }
        return number.doubleValue
    }

    private static func iso8601Date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func isSubagentMarker(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("subagent") == .orderedSame
    }

    private static func sourceContainsSubagentNode(_ value: Any?) -> Bool {
        if let string = value as? String {
            return isSubagentMarker(string)
        }
        if let array = value as? [Any] {
            return array.contains(where: sourceContainsSubagentNode)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nestedValue in
                isSubagentMarker(key)
                    || sourceContainsSubagentNode(nestedValue)
            }
        }
        return false
    }

    private static func summary(
        states: [String: RunningThreadFileState],
        cutoff: Date,
        now: Date
    ) -> RunningThreadSummary {
        var preferredBySessionID: [String: RunningThreadFileState] = [:]
        for state in states.values where state.modifiedAt >= cutoff && !state.sessionID.isEmpty {
            guard let current = preferredBySessionID[state.sessionID] else {
                preferredBySessionID[state.sessionID] = state
                continue
            }
            if stateIsNewer(state, than: current) {
                preferredBySessionID[state.sessionID] = state
            }
        }

        var main = 0
        var subagents = 0
        for state in preferredBySessionID.values where state.lifecycle == .running {
            if state.isSubagent {
                subagents += 1
            } else {
                main += 1
            }
        }
        return RunningThreadSummary(
            main: main,
            subagents: subagents,
            updatedAt: now,
            freshness: .fresh
        )
    }

    private static func stateIsNewer(
        _ candidate: RunningThreadFileState,
        than current: RunningThreadFileState
    ) -> Bool {
        switch (candidate.lifecycleAt, current.lifecycleAt) {
        case let (.some(candidateTimestamp), .some(currentTimestamp)):
            if candidateTimestamp != currentTimestamp {
                return candidateTimestamp > currentTimestamp
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            if candidate.lifecycle != .unknown, current.lifecycle == .unknown {
                return true
            }
            if candidate.lifecycle == .unknown, current.lifecycle != .unknown {
                return false
            }
        }
        return candidate.modifiedAt > current.modifiedAt
            || candidate.modifiedAt == current.modifiedAt && candidate.offset > current.offset
    }
}
