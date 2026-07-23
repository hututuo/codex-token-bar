import CryptoKit
import Foundation

enum CodexUsageDiscoveryError: LocalizedError {
    case selectedHomeUnavailable(path: String)
    case selectedHomeIdentityChanged(path: String)
    case traversalFailed(path: String, reason: String)
    case stateDatabaseReadFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .selectedHomeUnavailable(let path):
            return "所选 Codex Home 身份无法验证：\(path)"
        case .selectedHomeIdentityChanged(let path):
            return "所选 Codex Home 身份已变化，已停止读取：\(path)"
        case .traversalFailed(let path, let reason):
            return "会话目录遍历失败：\(path)（\(reason)）"
        case .stateDatabaseReadFailed(let path, let reason):
            return "活动会话索引读取失败：\(path)（\(reason)）"
        }
    }
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
        var previousTotal: Int?
        var currentUserPromptOffset: UInt64?
        var assistantStartOffset: UInt64?
        var forkReplayStartedAt: Date?
        var isSkippingForkReplay = false
        var lastSkippedForkReplayTokenAt: Date?
        var eventCount = 0

        let stream = try streamIndexedSessionLines(
            from: file,
            endingAt: endOffset
        ) { lineOffset, lineString in
            try autoreleasepool {
                if forkReplayStartedAt == nil,
                   let timestamp = parseSessionMetaForkTimestamp(lineString) {
                    forkReplayStartedAt = timestamp
                    isSkippingForkReplay = true
                    return
                }

                if let timestamp = parsePayloadHeaderTimestamp(
                    lineString,
                    expectedType: "user_message"
                ) {
                    if isSkippingForkReplay {
                        let replayReference = lastSkippedForkReplayTokenAt ?? forkReplayStartedAt
                        guard let replayReference,
                              timestamp.timeIntervalSince(replayReference) >= Self.forkReplayExitGrace else {
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
            endedWithNewline: stream.endedWithNewline,
            contentHash: stream.contentHash
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
            daily: cacheUsage.daily,
            hourly: cacheUsage.hourly,
            recentBins: cacheUsage.recentBins,
            sessions: cacheUsage.sessions,
            turns: hydratedTurns
        )
    }

    func usageJSONLFiles() throws -> [URL] {
        let canonicalHome = try canonicalSelectedHome()
        var files: [URL] = []
        if fileManager.fileExists(atPath: dataSource.sessionsRoot.path) {
            let sessionFiles = try jsonlFiles(
                under: dataSource.sessionsRoot,
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
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> SessionTreeSignature {
        SessionTreeSignature(
            localDate: localDateString(for: now, timeZone: timeZone),
            utcOffsetSeconds: timeZone.secondsFromGMT(for: now),
            files: files
                .compactMap(sessionCacheKey(for:))
                .sorted { $0.path < $1.path },
            stateDatabase: sessionCacheKey(for: dataSource.stateDatabase)
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
                reason: error.localizedDescription
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
                reason: error.localizedDescription
            )
        }
        return Set(rows.compactMap { row in
            row.count > 1 ? row[1] : nil
        })
    }

    private func sqliteRows(db: String, sql: String) throws -> [[String]] {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: db),
            readOnly: true,
            busyTimeoutMilliseconds: 1_000,
            enableWAL: false
        )
        return try driver.readRows(sql) { statement in
            (0..<statement.columnCount).map { column in
                statement.text(column) ?? ""
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

    private func parseSessionMetaForkTimestamp(_ line: String) -> Date? {
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

        if let timestampString = object["timestamp"] as? String,
           let timestamp = parseDate(timestampString) {
            return timestamp
        }
        if let timestampString = payload["timestamp"] as? String,
           let timestamp = parseDate(timestampString) {
            return timestamp
        }
        return nil
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
        return SessionCacheKey(
            path: file.resolvingSymlinksInPath().path,
            size: size,
            modifiedAt: modifiedAt
        )
    }

    private func streamIndexedSessionLines(
        from file: URL,
        startingAt offset: UInt64 = 0,
        endingAt endOffset: UInt64? = nil,
        handleLine: (UInt64, String) throws -> Void
    ) throws -> SessionLineStreamResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        var pending = Data()
        var pendingStartOffset = offset
        var hasher = SHA256()
        let newline = Data([0x0A])
        let needles = [
            Data(#""token_count""#.utf8),
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

        if !pending.isEmpty {
            if needles.contains(where: { pending.range(of: $0) != nil }) {
                try handleLine(pendingStartOffset, String(decoding: pending, as: UTF8.self))
            }
            pendingStartOffset += UInt64(pending.count)
        }
        return SessionLineStreamResult(
            lastOffset: pendingStartOffset,
            endedWithNewline: pending.isEmpty,
            contentHash: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
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
