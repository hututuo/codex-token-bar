import CryptoKit
import Darwin
import Foundation

enum CodexUsageDiscoveryError: LocalizedError, SQLiteTransientReadFailureReporting {
    case selectedHomeUnavailable(path: String)
    case selectedHomeIdentityChanged(path: String)
    case traversalFailed(path: String, reason: String)
    case stateDatabaseReadFailed(path: String, reason: String, transient: Bool)

    var isTransientReadFailure: Bool {
        guard case .stateDatabaseReadFailed(_, _, let transient) = self else {
            return false
        }
        return transient
    }

    var errorDescription: String? {
        switch self {
        case .selectedHomeUnavailable(let path):
            return "所选 Codex Home 身份无法验证：\(path)"
        case .selectedHomeIdentityChanged(let path):
            return "所选 Codex Home 身份已变化，已停止读取：\(path)"
        case .traversalFailed(let path, let reason):
            return "会话目录遍历失败：\(path)（\(reason)）"
        case .stateDatabaseReadFailed(let path, let reason, _):
            return "活动会话索引读取失败：\(path)（\(reason)）"
        }
    }
}

private struct IndexedSessionChunkHasher {
    private static let chunkSize: UInt64 = 4 * 1_024 * 1_024

    private var absoluteOffset: UInt64
    private var chunkIndex: UInt64
    private var chunkByteCount: UInt64 = 0
    private var chunkHasher = SHA256()
    private var chunks: [CodexUsageAnalyzer.IndexedChunkHash] = []
    private let validationBoundary: UInt64?
    private var validationChunkHash: CodexUsageAnalyzer.IndexedChunkHash?

    init(hashingStartOffset: UInt64, validationBoundary: UInt64?) {
        precondition(hashingStartOffset % Self.chunkSize == 0)
        absoluteOffset = hashingStartOffset
        chunkIndex = hashingStartOffset / Self.chunkSize
        self.validationBoundary = validationBoundary
    }

    mutating func update(_ data: Data) {
        var consumed = 0
        while consumed < data.count {
            let chunkRemaining = Self.chunkSize - chunkByteCount
            let validationRemaining = validationBoundary.flatMap { boundary in
                boundary > absoluteOffset ? boundary - absoluteOffset : nil
            } ?? UInt64.max
            let amount = min(
                UInt64(data.count - consumed),
                min(chunkRemaining, validationRemaining)
            )
            if amount == 0 {
                captureValidationHash()
                continue
            }
            let count = Int(amount)
            chunkHasher.update(data: data[consumed..<(consumed + count)])
            chunkByteCount += amount
            absoluteOffset += amount
            consumed += count
            if chunkByteCount == Self.chunkSize {
                finishChunk()
            }
            captureValidationHash()
        }
    }

    mutating func finish() -> (
        chunks: [CodexUsageAnalyzer.IndexedChunkHash],
        validationChunkHash: CodexUsageAnalyzer.IndexedChunkHash?
    ) {
        if chunkByteCount > 0 {
            finishChunk()
        }
        return (chunks, validationChunkHash)
    }

    private mutating func finishChunk() {
        guard chunkByteCount > 0 else { return }
        let snapshot = chunkHasher
        chunks.append(
            CodexUsageAnalyzer.IndexedChunkHash(
                index: chunkIndex,
                byteCount: chunkByteCount,
                sha256: snapshot.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        )
        chunkIndex += 1
        chunkByteCount = 0
        chunkHasher = SHA256()
    }

    private mutating func captureValidationHash() {
        guard let validationBoundary,
              absoluteOffset == validationBoundary,
              validationChunkHash == nil,
              validationBoundary > 0 else {
            return
        }
        if chunkByteCount == 0 {
            validationChunkHash = chunks.last
        } else {
            let snapshot = chunkHasher
            validationChunkHash = CodexUsageAnalyzer.IndexedChunkHash(
                index: chunkIndex,
                byteCount: chunkByteCount,
                sha256: snapshot.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }
    }
}

private func isCompleteIndexedJSONLine(_ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
}

extension CodexUsageAnalyzer {
    private static let forkReplayExitGrace: TimeInterval = 2

    private struct PayloadHeader: Decodable {
        struct Payload: Decodable {
            let type: String
        }

        let timestamp: String
        let payload: Payload
    }

    func parseSessionIntoHistoryIndex(
        file: URL,
        sessionID: String,
        endingAt endOffset: UInt64,
        insertFingerprint: (UsageSnapshotFingerprint) throws -> Bool,
        emit: (IndexedTokenEvent) throws -> Void
    ) throws -> IndexedSessionParseResult {
        try parseSessionIntoHistoryIndex(
            file: file,
            sessionID: sessionID,
            request: .full(endOffset: endOffset),
            insertFingerprint: insertFingerprint,
            emit: emit
        )
    }

    func parseSessionIntoHistoryIndex(
        file: URL,
        sessionID: String,
        request: IndexedSessionParseRequest,
        insertFingerprint: (UsageSnapshotFingerprint) throws -> Bool,
        emit: (IndexedTokenEvent) throws -> Void
    ) throws -> IndexedSessionParseResult {
        var previousTotal = request.initialState.previousTotalTokens
        var currentUserPromptOffset = request.initialState.currentUserPromptOffset
        var assistantStartOffset = request.initialState.assistantStartOffset
        var currentModel = request.initialState.currentModel
        var forkReplayStartedAt = request.initialState.forkReplayStartedAt
        var isSkippingForkReplay = request.initialState.isSkippingForkReplay
        var isExplicitSubagentFork = request.initialState.isExplicitSubagentFork
        var lastSkippedForkReplayTokenAt =
            request.initialState.lastSkippedForkReplayTokenAt
        var eventCount = 0

        let stream = try streamIndexedSessionLines(
            from: file,
            startingAt: request.parsingStartOffset,
            endingAt: request.endOffset,
            chunkHashingFrom: request.hashingStartOffset,
            validationBoundary: request.validationBoundary
        ) { lineOffset, lineString in
            try autoreleasepool {
                if forkReplayStartedAt == nil,
                   let metadata = parseSessionMetaForkMetadata(lineString) {
                    forkReplayStartedAt = metadata.timestamp
                    isSkippingForkReplay = true
                    isExplicitSubagentFork = metadata.isExplicitSubagent
                    return
                }

                if let turnContext = parseTurnContext(lineString) {
                    currentModel = turnContext.model
                    // Forked rollout files replay the parent's turn_context
                    // rows as well as its token snapshots. A turn_context is a
                    // child boundary only after it has moved beyond the replay
                    // grace window; using the first replayed turn_context here
                    // counts the complete parent history once per subagent.
                    if isExplicitSubagentFork,
                       isSkippingForkReplay,
                       let timestamp = turnContext.timestamp,
                       let replayReference = lastSkippedForkReplayTokenAt
                           ?? forkReplayStartedAt,
                       timestamp.timeIntervalSince(replayReference)
                           > Self.forkReplayExitGrace {
                        isSkippingForkReplay = false
                    }
                    return
                }

                if let timestamp = parsePayloadHeaderTimestamp(
                    lineString,
                    expectedType: "user_message"
                ) {
                    if isSkippingForkReplay {
                        let replayReference = lastSkippedForkReplayTokenAt ?? forkReplayStartedAt
                        // 跨端契约：恰好等于宽限（2s）仍视为重放，严格大于才退出，
                        // 与 Rust session_parser.rs 的 `> FORK_REPLAY_EXIT_GRACE` 一致。
                        guard let replayReference,
                              timestamp.timeIntervalSince(replayReference) > Self.forkReplayExitGrace else {
                            return
                        }
                        isSkippingForkReplay = false
                    }
                    currentUserPromptOffset = lineOffset
                    assistantStartOffset = nil
                    return
                }

                if parsePayloadHeaderTimestamp(
                    lineString,
                    expectedType: "agent_message"
                ) != nil {
                    guard !isSkippingForkReplay else { return }
                    if assistantStartOffset == nil {
                        assistantStartOffset = lineOffset
                    }
                    return
                }

                guard let usageLine = parseTokenUsageLine(lineString) else {
                    return
                }

                let totalTokens = usageLine.total?.totalTokens
                let previousHighWater = previousTotal
                if let totalTokens {
                    previousTotal = max(previousTotal ?? totalTokens, totalTokens)
                }
                let isNewSnapshot = try usageSnapshotFingerprint(for: usageLine)
                    .map(insertFingerprint) ?? true
                if isSkippingForkReplay {
                    lastSkippedForkReplayTokenAt = usageLine.timestamp
                    return
                }
                guard isNewSnapshot else { return }

                let lastTokens = usageLine.last?.totalTokens
                let delta: Int
                if let lastTokens, lastTokens > 0 {
                    delta = lastTokens
                } else if let totalTokens {
                    delta = previousHighWater.map { max(0, totalTokens - $0) } ?? totalTokens
                } else {
                    delta = 0
                }
                guard delta > 0 else { return }

                let event = TokenEvent(
                    timestamp: usageLine.timestamp,
                    sessionID: sessionID,
                    model: currentModel,
                    tokens: delta,
                    inputTokens: usageLine.last?.inputTokens ?? 0,
                    cachedInputTokens: usageLine.last?.cachedInputTokens ?? 0,
                    outputTokens: usageLine.last?.outputTokens ?? 0,
                    reasoningOutputTokens: usageLine.last?.reasoningOutputTokens ?? 0,
                    userPrompt: "",
                    assistantResponse: ""
                )
                try emit(
                    IndexedTokenEvent(
                        event: event,
                        sourceOffset: lineOffset,
                        userPromptOffset: currentUserPromptOffset,
                        assistantStartOffset: assistantStartOffset
                    )
                )
                eventCount += 1
                assistantStartOffset = nil
            }
        }

        return IndexedSessionParseResult(
            eventCount: eventCount,
            lastOffset: stream.lastOffset,
            resumeOffset: stream.resumeOffset,
            endedWithNewline: stream.endedWithNewline,
            contentHash: stream.contentHash,
            state: IndexedSessionParserState(
                previousTotalTokens: previousTotal,
                forkReplayStartedAt: forkReplayStartedAt,
                isSkippingForkReplay: isSkippingForkReplay,
                isExplicitSubagentFork: isExplicitSubagentFork,
                lastSkippedForkReplayTokenAt: lastSkippedForkReplayTokenAt,
                currentUserPromptOffset: currentUserPromptOffset,
                assistantStartOffset: assistantStartOffset,
                currentModel: currentModel
            ),
            chunkHashes: stream.chunkHashes,
            validationChunkHash: stream.validationChunkHash
        )
    }

    func hydratingTurnExcerpts(
        in cacheUsage: TokenCacheUsage,
        from index: CodexUsageHistoryIndex
    ) -> TokenCacheUsage {
        guard !cacheUsage.turns.isEmpty,
              let references = try? index.turnSourceReferences(
                for: cacheUsage.turns.map(\.id)
              ),
              !references.isEmpty else {
            return cacheUsage
        }

        var prompts: [String: String] = [:]
        var assistants: [String: String] = [:]
        let grouped = Dictionary(grouping: references.values, by: \.file.path)

        for (_, fileReferences) in grouped {
            guard let file = fileReferences.first?.file else { continue }
            for reference in fileReferences {
                guard let offset = reference.userPromptOffset,
                      let line = try? readIndexedLine(from: file, at: offset),
                      let message = parsePayloadMessageLine(line, expectedType: "user_message")?.message else {
                    continue
                }
                prompts[reference.stableID] = excerpt(message, limit: 180)
            }

            let assistantReferences = fileReferences.filter {
                guard let start = $0.assistantStartOffset else { return false }
                return start < $0.eventOffset
            }
            guard let firstOffset = assistantReferences.compactMap(\.assistantStartOffset).min(),
                  let lastOffset = assistantReferences.map(\.eventOffset).max() else {
                continue
            }

            _ = try? streamIndexedSessionLines(
                from: file,
                startingAt: firstOffset,
                endingAt: lastOffset
            ) { lineOffset, lineString in
                guard let message = parsePayloadMessageLine(
                    lineString,
                    expectedType: "agent_message"
                )?.message else {
                    return
                }
                for reference in assistantReferences {
                    guard let start = reference.assistantStartOffset,
                          lineOffset >= start,
                          lineOffset < reference.eventOffset else {
                        continue
                    }
                    assistants[reference.stableID] = appendingExcerpt(
                        assistants[reference.stableID] ?? "",
                        value: message,
                        limit: 220
                    )
                }
            }
        }

        let hydratedTurns = cacheUsage.turns.map { turn in
            TurnCacheUsage(
                id: turn.id,
                sessionID: turn.sessionID,
                sessionTitle: turn.sessionTitle,
                timestamp: turn.timestamp,
                turnIndexInSession: turn.turnIndexInSession,
                userPrompt: prompts[turn.id] ?? turn.userPrompt,
                assistantResponse: assistants[turn.id] ?? turn.assistantResponse,
                breakdown: turn.breakdown
            )
        }
        return TokenCacheUsage(
            total: cacheUsage.total,
            modelBreakdowns: cacheUsage.modelBreakdowns,
            dailyModelBreakdowns: cacheUsage.dailyModelBreakdowns,
            daily: cacheUsage.daily,
            hourly: cacheUsage.hourly,
            recentBins: cacheUsage.recentBins,
            sessions: cacheUsage.sessions,
            turns: hydratedTurns,
            attributionEvents: cacheUsage.attributionEvents,
            attributionEventsComplete: cacheUsage.attributionEventsComplete,
            attributionProvenanceEpoch: cacheUsage.attributionProvenanceEpoch,
            attributionGeneration: cacheUsage.attributionGeneration,
            attributionUnsafeSinceGeneration:
                cacheUsage.attributionUnsafeSinceGeneration,
            attributionCurrentScanUnsafeCauseDetected:
                cacheUsage.attributionCurrentScanUnsafeCauseDetected,
            attributionSourceMutationDetected: cacheUsage.attributionSourceMutationDetected
        )
    }

    func usageJSONLFiles() throws -> [URL] {
        let canonicalHome = try canonicalSelectedHome()
        var files: [URL] = []
        let historyRoots = [
            dataSource.sessionsRoot,
            canonicalHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        for root in historyRoots where fileManager.fileExists(atPath: root.path) {
            let sessionFiles = try jsonlFiles(
                under: root,
                canonicalHome: canonicalHome
            )
            files.append(contentsOf: sessionFiles)
        }
        files.append(contentsOf: try activeStateRolloutFiles(canonicalHome: canonicalHome))
        return deduplicateJSONLFiles(files)
    }

    private func jsonlFiles(under root: URL, canonicalHome: URL) throws -> [URL] {
        guard let rootValues = fileResourceValues(for: root),
              rootValues.isSymbolicLink != true,
              rootValues.isDirectory == true,
              isContained(root.resolvingSymlinksInPath(), in: canonicalHome) else {
            throw CodexUsageDiscoveryError.traversalFailed(
                path: root.path,
                reason: "根目录不可读取或不再位于所选 Home 内"
            )
        }

        var files: [URL] = []
        var pendingDirectories: [(url: URL, depth: Int)] = [(root, 0)]

        while let directory = pendingDirectories.popLast() {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw CodexUsageDiscoveryError.traversalFailed(
                    path: directory.url.path,
                    reason: error.localizedDescription
                )
            }
            var childDirectories: [URL] = []

            for child in children.sorted(by: { $0.path < $1.path }) {
                guard let values = fileResourceValues(for: child) else {
                    throw CodexUsageDiscoveryError.traversalFailed(
                        path: child.path,
                        reason: "无法读取文件类型"
                    )
                }
                guard values.isSymbolicLink != true else {
                    continue
                }
                if values.isDirectory == true {
                    let resolvedDirectory = child.resolvingSymlinksInPath()
                    guard isContained(resolvedDirectory, in: canonicalHome) else {
                        continue
                    }
                    childDirectories.append(child)
                } else if values.isRegularFile == true,
                          let file = try trustedJSONLFile(child, canonicalHome: canonicalHome) {
                    files.append(file)
                }
            }

            for childDirectory in childDirectories.reversed() {
                pendingDirectories.append((childDirectory, directory.depth + 1))
            }
        }

        return files
    }

    func sessionID(from file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(5).joined(separator: "-")
    }

    func sessionTreeSignature(
        for files: [URL],
        attributionProvenanceEpoch: String,
        attributionGeneration: Int64,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> SessionTreeSignature {
        SessionTreeSignature(
            localDate: localDateString(for: now, timeZone: timeZone),
            utcOffsetSeconds: timeZone.secondsFromGMT(for: now),
            files: files
                .compactMap(sessionCacheKey(for:))
                .sorted { $0.path < $1.path },
            stateDatabase: sessionCacheKey(for: dataSource.stateDatabase),
            attributionProvenanceEpoch: attributionProvenanceEpoch,
            attributionGeneration: attributionGeneration
        )
    }

    private func activeStateRolloutFiles(canonicalHome: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: dataSource.stateDatabase.path) else {
            return []
        }
        let columns = try threadColumnNames()
        guard columns.contains("rollout_path") else {
            return []
        }
        let archivedFilter = columns.contains("archived")
            ? "COALESCE(archived, 0) = 0"
            : "1 = 1"
        let sql = """
        SELECT rollout_path
        FROM threads
        WHERE \(archivedFilter)
          AND rollout_path IS NOT NULL
          AND rollout_path <> '';
        """
        let rows: [[String]]
        do {
            rows = try sqliteRows(db: dataSource.stateDatabase.path, sql: sql)
        } catch {
            throw CodexUsageDiscoveryError.stateDatabaseReadFailed(
                path: dataSource.stateDatabase.path,
                reason: error.localizedDescription,
                transient: SQLiteReadRecovery.isTransientReadFailure(error)
            )
        }
        return try rows.compactMap { row in
            guard let rawPath = row.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty else {
                return nil
            }
            return try trustedJSONLFile(
                normalizedRolloutPath(rawPath),
                canonicalHome: canonicalHome
            )
        }
    }

    private func threadColumnNames() throws -> Set<String> {
        let rows: [[String]]
        do {
            rows = try sqliteRows(db: dataSource.stateDatabase.path, sql: "PRAGMA table_info(threads);")
        } catch {
            throw CodexUsageDiscoveryError.stateDatabaseReadFailed(
                path: dataSource.stateDatabase.path,
                reason: error.localizedDescription,
                transient: SQLiteReadRecovery.isTransientReadFailure(error)
            )
        }
        return Set(rows.compactMap { row in
            row.count > 1 ? row[1] : nil
        })
    }

    private func sqliteRows(db: String, sql: String) throws -> [[String]] {
        try SQLiteReadRecovery.run {
            // Recreate the read-only connection for every retry. Codex owns this
            // WAL database and may be checkpointing it while Token Bar discovers
            // active rollout paths; reusing the failed handle can preserve a
            // transient SQLITE_IOERR state and unnecessarily stale the whole
            // precise-usage snapshot.
            let driver = SQLiteDatabaseDriver(
                url: URL(fileURLWithPath: db),
                readOnly: true,
                createsFileIfMissing: false,
                busyTimeoutMilliseconds: 1_000,
                enableWAL: false,
                consistency: .externallyOwnedWAL
            )
            return try driver.readRows(sql) { statement in
                (0..<statement.columnCount).map { column in
                    statement.text(column) ?? ""
                }
            }
        }
    }

    private func normalizedRolloutPath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded)
        }
        return dataSource.codexHome.appendingPathComponent(expanded)
    }

    private func deduplicateJSONLFiles(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        var deduped: [URL] = []
        for file in files {
            let key = canonicalPath(for: file)
            if seen.insert(key).inserted {
                deduped.append(file)
            }
        }
        return deduped.sorted { $0.path < $1.path }
    }

    private func canonicalPath(for file: URL) -> String {
        file.resolvingSymlinksInPath().path
    }

    private func canonicalSelectedHome() throws -> URL {
        let home = dataSource.codexHome.standardizedFileURL
        guard let values = fileResourceValues(for: home),
              values.isDirectory == true else {
            throw CodexUsageDiscoveryError.selectedHomeUnavailable(path: home.path)
        }
        guard values.isSymbolicLink != true else {
            throw CodexUsageDiscoveryError.selectedHomeIdentityChanged(path: home.path)
        }
        guard let expectedIdentity = dataSource.homeIdentity,
              let currentIdentity = CodexHomeIdentity.read(at: home) else {
            throw CodexUsageDiscoveryError.selectedHomeUnavailable(path: home.path)
        }
        guard currentIdentity == expectedIdentity else {
            throw CodexUsageDiscoveryError.selectedHomeIdentityChanged(path: home.path)
        }
        return home.resolvingSymlinksInPath()
    }

    private func trustedJSONLFile(_ file: URL, canonicalHome: URL) throws -> URL? {
        guard file.pathExtension == "jsonl",
              fileManager.fileExists(atPath: file.path) else {
            return nil
        }
        guard let values = fileResourceValues(for: file) else {
            throw CodexUsageDiscoveryError.traversalFailed(
                path: file.path,
                reason: "无法读取 JSONL 文件属性"
            )
        }
        guard values.isSymbolicLink != true,
              values.isRegularFile == true else {
            return nil
        }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(resolved, in: canonicalHome) else {
            return nil
        }
        guard let resolvedValues = fileResourceValues(for: resolved) else {
            throw CodexUsageDiscoveryError.traversalFailed(
                path: resolved.path,
                reason: "无法验证 JSONL 文件属性"
            )
        }
        guard resolvedValues.isSymbolicLink != true,
              resolvedValues.isRegularFile == true else {
            return nil
        }
        return resolved
    }

    private func fileResourceValues(for file: URL) -> URLResourceValues? {
        try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private func localDateString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func usageSnapshotFingerprint(for usageLine: ParsedTokenUsageLine) -> UsageSnapshotFingerprint? {
        guard let total = usageLine.total else { return nil }
        return UsageSnapshotFingerprint(total: total, last: usageLine.last)
    }

    private struct ForkSessionMetadata {
        let timestamp: Date
        let isExplicitSubagent: Bool
    }

    private func parseSessionMetaForkMetadata(_ line: String) -> ForkSessionMetadata? {
        guard line.contains("session_meta"),
              line.contains("forked_from_id"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let forkedFromID = payload["forked_from_id"] as? String,
              !forkedFromID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap(parseDate)
            ?? (payload["timestamp"] as? String).flatMap(parseDate)
        guard let timestamp else { return nil }

        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let hasThreadSpawn = subagent?["thread_spawn"] is [String: Any]
        let threadSource = (payload["thread_source"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let agentRole = (payload["agent_role"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let agentPath = (payload["agent_path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isExplicitSubagent = hasThreadSpawn
            || threadSource == "subagent"
            || !(agentRole?.isEmpty ?? true)
            || !(agentPath?.isEmpty ?? true)
        return ForkSessionMetadata(timestamp: timestamp, isExplicitSubagent: isExplicitSubagent)
    }

    private func extractPayloadMessage(from line: String, expectedType: String) -> String? {
        parsePayloadMessageLine(line, expectedType: expectedType)?.message
    }

    private func parsePayloadHeaderTimestamp(_ line: String, expectedType: String) -> Date? {
        guard line.contains(#""payload""#),
              line.contains(expectedType),
              let data = line.data(using: .utf8),
              let header = try? JSONDecoder().decode(PayloadHeader.self, from: data),
              header.payload.type == expectedType else {
            return nil
        }
        return parseDate(header.timestamp)
    }

    private func parsePayloadMessageLine(_ line: String, expectedType: String) -> (timestamp: Date, message: String)? {
        guard line.contains(#""payload""#),
              line.contains(expectedType),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseDate(timestampString),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == expectedType,
              let message = payload["message"] as? String else {
            return nil
        }
        let normalized = normalizeExcerptText(message)
        return normalized.isEmpty ? nil : (timestamp, normalized)
    }

    private func parseTokenUsageLine(_ line: String) -> ParsedTokenUsageLine? {
        guard line.contains(#""token_count""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseDate(timestampString),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        let total = parseTokenUsage(info["total_token_usage"] as? [String: Any])
        let last = parseTokenUsage(info["last_token_usage"] as? [String: Any])
        guard total != nil || last != nil else { return nil }
        return ParsedTokenUsageLine(timestamp: timestamp, total: total, last: last)
    }

    private struct ParsedTurnContext {
        let model: String
        let timestamp: Date?
    }

    private func parseTurnContext(_ line: String) -> ParsedTurnContext? {
        guard line.contains(#""turn_context""#),
              line.contains(#""model""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "turn_context",
              let payload = object["payload"] as? [String: Any],
              let rawModel = payload["model"] as? String else {
            return nil
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return ParsedTurnContext(
            model: model,
            timestamp: (object["timestamp"] as? String).flatMap(parseDate)
        )
    }

    private func parseTokenUsage(_ raw: [String: Any]?) -> ParsedTokenUsage? {
        guard let raw,
              let totalTokens = intValue(raw["total_tokens"]) else {
            return nil
        }

        return ParsedTokenUsage(
            inputTokens: intValue(raw["input_tokens"]) ?? 0,
            cachedInputTokens: intValue(raw["cached_input_tokens"]) ?? 0,
            outputTokens: intValue(raw["output_tokens"]) ?? 0,
            reasoningOutputTokens: intValue(raw["reasoning_output_tokens"]) ?? 0,
            totalTokens: totalTokens
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func normalizeExcerptText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func excerpt(_ value: String, limit: Int) -> String {
        let normalized = normalizeExcerptText(value)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }

    private func appendingExcerpt(_ existing: String, value: String, limit: Int) -> String {
        guard !value.isEmpty, existing.count < limit else { return existing }
        let separator = existing.isEmpty ? "" : " "
        let remaining = max(limit - existing.count - separator.count, 0)
        guard remaining > 0 else { return existing }
        let prefix = String(value.prefix(remaining))
        let suffix = value.count > remaining ? "..." : ""
        return existing + separator + prefix + suffix
    }

    private func sessionCacheKey(for file: URL) -> SessionCacheKey? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value
            ?? attributes[.size] as? UInt64
            ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var status = stat()
        let hasStatus = lstat(file.path, &status) == 0
        return SessionCacheKey(
            path: file.resolvingSymlinksInPath().path,
            size: size,
            modifiedAt: modifiedAt,
            deviceID: hasStatus ? UInt64(status.st_dev) : nil,
            inode: hasStatus ? UInt64(status.st_ino) : nil,
            statusChangedSeconds: hasStatus ? Int64(status.st_ctimespec.tv_sec) : nil,
            statusChangedNanoseconds: hasStatus ? Int64(status.st_ctimespec.tv_nsec) : nil
        )
    }

    private func streamIndexedSessionLines(
        from file: URL,
        startingAt offset: UInt64 = 0,
        endingAt endOffset: UInt64? = nil,
        chunkHashingFrom hashingStartOffset: UInt64? = nil,
        validationBoundary: UInt64? = nil,
        handleLine: (UInt64, String) throws -> Void
    ) throws -> SessionLineStreamResult {
        let hashingOffset = hashingStartOffset ?? offset
        guard hashingOffset <= offset,
              endOffset.map({ offset <= $0 }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let validationBoundary,
           validationBoundary < hashingOffset
            || endOffset.map({ validationBoundary > $0 }) == true {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if hashingOffset > 0 {
            try handle.seek(toOffset: hashingOffset)
        }

        var hasher = SHA256()
        var chunkHasher = hashingStartOffset.map {
            IndexedSessionChunkHasher(
                hashingStartOffset: $0,
                validationBoundary: validationBoundary
            )
        }
        var skipRemaining = offset - hashingOffset
        while skipRemaining > 0 {
            let requested = Int(min(skipRemaining, 1_048_576))
            let data = handle.readData(ofLength: requested)
            guard !data.isEmpty else {
                throw CodexUsageSourceChangedError(path: file.path)
            }
            hasher.update(data: data)
            chunkHasher?.update(data)
            skipRemaining -= UInt64(data.count)
        }

        var pending = Data()
        var pendingStartOffset = offset
        let newline = Data([0x0A])
        let needles = [
            Data(#""token_count""#.utf8),
            Data(#""turn_context""#.utf8),
            Data(#""user_message""#.utf8),
            Data(#""agent_message""#.utf8),
            Data(#""session_meta""#.utf8)
        ]
        var reachedEnd = false

        while !reachedEnd {
            let requestedBytes: Int
            if let endOffset {
                guard pendingStartOffset + UInt64(pending.count) < endOffset else { break }
                let remaining = endOffset - (pendingStartOffset + UInt64(pending.count))
                requestedBytes = min(1_048_576, Int(min(remaining, UInt64(Int.max))))
            } else {
                requestedBytes = 1_048_576
            }
            guard requestedBytes > 0 else { break }

            let data = handle.readData(ofLength: requestedBytes)
            if data.isEmpty {
                reachedEnd = true
            } else {
                hasher.update(data: data)
                chunkHasher?.update(data)
                pending.append(data)
            }

            var searchStart = pending.startIndex
            var consumedOffset = pendingStartOffset
            while let newlineRange = pending[searchStart...].range(of: newline) {
                let lineRange = searchStart..<newlineRange.lowerBound
                let lineData = pending[lineRange]
                let lineOffset = pendingStartOffset
                    + UInt64(pending.distance(from: pending.startIndex, to: searchStart))
                if needles.contains(where: { lineData.range(of: $0) != nil }) {
                    try handleLine(lineOffset, String(decoding: lineData, as: UTF8.self))
                }
                let consumedBytes = pending.distance(
                    from: pending.startIndex,
                    to: newlineRange.upperBound
                )
                consumedOffset = pendingStartOffset + UInt64(consumedBytes)
                searchStart = newlineRange.upperBound
            }

            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
                pendingStartOffset = consumedOffset
            }
        }

        var resumeOffset = pendingStartOffset
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            if isCompleteIndexedJSONLine(pending) {
                if needles.contains(where: { pending.range(of: $0) != nil }) {
                    try handleLine(pendingStartOffset, line)
                }
                resumeOffset = pendingStartOffset + UInt64(pending.count)
            }
            pendingStartOffset += UInt64(pending.count)
        }
        let chunkResult = chunkHasher?.finish()
        return SessionLineStreamResult(
            lastOffset: pendingStartOffset,
            resumeOffset: resumeOffset,
            endedWithNewline: pending.isEmpty,
            contentHash: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined(),
            chunkHashes: chunkResult?.chunks ?? [],
            validationChunkHash: chunkResult?.validationChunkHash
        )
    }

    private func readIndexedLine(from file: URL, at offset: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var line = Data()
        let newline = UInt8(ascii: "\n")
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty {
                break
            }
            if let newlineIndex = chunk.firstIndex(of: newline) {
                line.append(chunk[..<newlineIndex])
                break
            }
            line.append(chunk)
        }
        return String(decoding: line, as: UTF8.self)
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
    }
}
