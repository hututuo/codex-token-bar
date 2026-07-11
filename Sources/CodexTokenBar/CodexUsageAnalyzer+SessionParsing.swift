import Foundation

enum CodexUsageDiscoveryError: LocalizedError {
    case selectedHomeUnavailable(path: String)
    case selectedHomeIdentityChanged(path: String)
    case traversalFailed(path: String, reason: String)
    case traversalLimitExceeded(path: String, limit: String)
    case stateDatabaseReadFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .selectedHomeUnavailable(let path):
            return "所选 Codex Home 身份无法验证：\(path)"
        case .selectedHomeIdentityChanged(let path):
            return "所选 Codex Home 身份已变化，已停止读取：\(path)"
        case .traversalFailed(let path, let reason):
            return "会话目录遍历失败：\(path)（\(reason)）"
        case .traversalLimitExceeded(let path, let limit):
            return "会话目录遍历超过安全上限：\(path)（\(limit)）"
        case .stateDatabaseReadFailed(let path, let reason):
            return "活动会话索引读取失败：\(path)（\(reason)）"
        }
    }
}

extension CodexUsageAnalyzer {
    private static let forkReplayExitGrace: TimeInterval = 2
    private static let maximumSessionTraversalDepth = 64
    private static let maximumSessionTraversalEntries = 200_000

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
        var visitedEntries = 0

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
                visitedEntries += 1
                guard visitedEntries <= Self.maximumSessionTraversalEntries else {
                    throw CodexUsageDiscoveryError.traversalLimitExceeded(
                        path: root.path,
                        limit: "最多 \(Self.maximumSessionTraversalEntries) 个条目"
                    )
                }
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
                    guard directory.depth < Self.maximumSessionTraversalDepth else {
                        throw CodexUsageDiscoveryError.traversalLimitExceeded(
                            path: child.path,
                            limit: "最大深度 \(Self.maximumSessionTraversalDepth)"
                        )
                    }
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

    func parseSession(file: URL, sessionID: String) -> [TokenEvent] {
        guard let cacheKey = sessionCacheKey(for: file) else {
            return parseFullSession(file: file, sessionID: sessionID).events
        }
        let cachePath = cacheKey.path

        if let cached = Self.sessionEventCache.cachedSession(for: cachePath, key: cacheKey) {
            RefreshPerformanceProbe.event("usageAnalyzer.session.cacheHit", metadata: [
                "file": file.lastPathComponent,
                "size": String(cacheKey.size),
                "events": String(cached.events.count)
            ])
            return cached.events
        }

        if let cached = Self.sessionEventCache.appendableSession(for: cachePath, currentKey: cacheKey) {
            let trace = RefreshPerformanceProbe.begin("usageAnalyzer.session.incrementalParse", metadata: [
                "file": file.lastPathComponent,
                "size": String(cacheKey.size),
                "previousSize": String(cached.key.size),
                "lastOffset": String(cached.lastOffset),
                "appendBytes": String(cacheKey.size > cached.lastOffset ? cacheKey.size - cached.lastOffset : 0)
            ])
            let appended = parseSession(
                file: file,
                sessionID: sessionID,
                startingAt: cached.lastOffset,
                previousTotal: cached.previousTotalTokens,
                initialForkReplayActive: cached.forkReplayActive,
                initialLastSkippedForkReplayTokenAt: cached.lastSkippedForkReplayTokenAt
            )
            let events = cached.events + appended.events
            Self.sessionEventCache.recordIncrementalSessionParseForTesting()
            Self.sessionEventCache.store(
                Self.SessionEventCache.CachedSession(
                    key: cacheKey,
                    events: events,
                    lastOffset: appended.lastOffset,
                    endedWithNewline: appended.endedWithNewline,
                    previousTotalTokens: appended.previousTotalTokens,
                    canIncrementFromOffset: appended.endedWithNewline,
                    forkReplayActive: appended.forkReplayActive,
                    lastSkippedForkReplayTokenAt: appended.lastSkippedForkReplayTokenAt
                ),
                for: cachePath
            )
            trace?.end("ok", metadata: [
                "newEvents": String(appended.events.count),
                "totalEvents": String(events.count),
                "lastOffset": String(appended.lastOffset),
                "endedWithNewline": appended.endedWithNewline ? "1" : "0"
            ])
            return events
        }

        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.session.fullParse", metadata: [
            "file": file.lastPathComponent,
            "size": String(cacheKey.size)
        ])
        let result = parseFullSession(file: file, sessionID: sessionID)
        Self.sessionEventCache.recordFullSessionParseForTesting()
        Self.sessionEventCache.store(
            Self.SessionEventCache.CachedSession(
                key: cacheKey,
                events: result.events,
                lastOffset: result.lastOffset,
                endedWithNewline: result.endedWithNewline,
                previousTotalTokens: result.previousTotalTokens,
                canIncrementFromOffset: result.endedWithNewline,
                forkReplayActive: result.forkReplayActive,
                lastSkippedForkReplayTokenAt: result.lastSkippedForkReplayTokenAt
            ),
            for: cachePath
        )
        trace?.end("ok", metadata: [
            "events": String(result.events.count),
            "lastOffset": String(result.lastOffset),
            "endedWithNewline": result.endedWithNewline ? "1" : "0"
        ])
        return result.events
    }

    private func parseFullSession(file: URL, sessionID: String) -> SessionParseResult {
        parseSession(file: file, sessionID: sessionID, startingAt: 0, previousTotal: nil)
    }

    private func parseSession(
        file: URL,
        sessionID: String,
        startingAt offset: UInt64,
        previousTotal initialPreviousTotal: Int?,
        initialForkReplayActive: Bool? = nil,
        initialLastSkippedForkReplayTokenAt: Date? = nil
    ) -> SessionParseResult {
        var events: [TokenEvent] = []
        var previousTotal = initialPreviousTotal
        var currentUserPrompt = ""
        var assistantFragments: [String] = []
        let forkReplayStartedAt = forkedSessionReplayStartedAt(for: file)
        var isSkippingForkReplay = initialForkReplayActive ?? (forkReplayStartedAt != nil)
        var lastSkippedForkReplayTokenAt = initialLastSkippedForkReplayTokenAt
        let stream = streamSessionLines(from: file, startingAt: offset) { lineString in
            if let messageLine = parsePayloadMessageLine(lineString, expectedType: "user_message") {
                if isSkippingForkReplay {
                    guard let lastSkippedForkReplayTokenAt,
                          messageLine.timestamp.timeIntervalSince(lastSkippedForkReplayTokenAt) >= Self.forkReplayExitGrace else {
                        return
                    }
                    isSkippingForkReplay = false
                }
                currentUserPrompt = messageLine.message
                assistantFragments.removeAll(keepingCapacity: true)
                return
            }

            if let messageLine = parsePayloadMessageLine(lineString, expectedType: "agent_message") {
                guard !isSkippingForkReplay else { return }
                assistantFragments.append(messageLine.message)
                return
            }

            guard let usageLine = parseTokenUsageLine(lineString) else {
                return
            }

            let totalTokens = usageLine.total?.totalTokens
            if isSkippingForkReplay {
                lastSkippedForkReplayTokenAt = usageLine.timestamp
                if let totalTokens {
                    previousTotal = totalTokens
                }
                return
            }

            let lastTokens = usageLine.last?.totalTokens
            let delta: Int

            if let totalTokens {
                if let previousTotal, totalTokens >= previousTotal {
                    delta = totalTokens - previousTotal
                } else {
                    delta = lastTokens ?? totalTokens
                }
                previousTotal = totalTokens
            } else {
                delta = lastTokens ?? 0
            }

            guard delta > 0 else { return }

            events.append(TokenEvent(
                timestamp: usageLine.timestamp,
                sessionID: sessionID,
                tokens: delta,
                inputTokens: usageLine.last?.inputTokens ?? 0,
                cachedInputTokens: usageLine.last?.cachedInputTokens ?? 0,
                outputTokens: usageLine.last?.outputTokens ?? 0,
                reasoningOutputTokens: usageLine.last?.reasoningOutputTokens ?? 0,
                userPrompt: excerpt(currentUserPrompt, limit: 180),
                assistantResponse: excerpt(assistantFragments.joined(separator: " "), limit: 220)
            ))
            assistantFragments.removeAll(keepingCapacity: true)
        }

        return SessionParseResult(
            events: events,
            lastOffset: stream.lastOffset,
            endedWithNewline: stream.endedWithNewline,
            previousTotalTokens: previousTotal,
            forkReplayActive: isSkippingForkReplay,
            lastSkippedForkReplayTokenAt: lastSkippedForkReplayTokenAt
        )
    }

    private func forkedSessionReplayStartedAt(for file: URL) -> Date? {
        guard let firstLine = readFirstLinePrefix(from: file),
              let timestamp = parseSessionMetaForkTimestamp(firstLine) else { return nil }
        return timestamp
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

    private func readFirstLinePrefix(from file: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(16_384, maxBytes - data.count))
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: newline) {
                data.append(chunk[..<newlineIndex])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func streamSessionLines(
        from file: URL,
        startingAt offset: UInt64 = 0,
        handleLine: (String) -> Void
    ) -> SessionLineStreamResult {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return SessionLineStreamResult(lastOffset: offset, endedWithNewline: true)
        }
        defer { try? handle.close() }
        if offset > 0 {
            try? handle.seek(toOffset: offset)
        }

        var pending = Data()
        var pendingStartOffset = offset
        let newline = Data([0x0A])
        let tokenNeedle = Data(#""token_count""#.utf8)
        let userMessageNeedle = Data(#""user_message""#.utf8)
        let agentMessageNeedle = Data(#""agent_message""#.utf8)

        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            pending.append(data)

            var searchStart = pending.startIndex
            var consumedOffset = pendingStartOffset
            while let newlineRange = pending[searchStart...].range(of: newline) {
                let lineRange = searchStart..<newlineRange.lowerBound
                let lineData = pending[lineRange]
                if lineData.range(of: tokenNeedle) != nil
                    || lineData.range(of: userMessageNeedle) != nil
                    || lineData.range(of: agentMessageNeedle) != nil {
                    handleLine(String(decoding: lineData, as: UTF8.self))
                }
                let consumedBytes = pending.distance(from: pending.startIndex, to: newlineRange.upperBound)
                consumedOffset = pendingStartOffset + UInt64(consumedBytes)
                searchStart = newlineRange.upperBound
            }

            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
                pendingStartOffset = consumedOffset
            }
        }

        if !pending.isEmpty,
           pending.range(of: tokenNeedle) != nil
            || pending.range(of: userMessageNeedle) != nil
            || pending.range(of: agentMessageNeedle) != nil {
            handleLine(String(decoding: pending, as: UTF8.self))
        }
        if !pending.isEmpty {
            pendingStartOffset += UInt64(pending.count)
        }
        return SessionLineStreamResult(lastOffset: pendingStartOffset, endedWithNewline: pending.isEmpty)
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
    }
}
