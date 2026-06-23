import Foundation

extension CodexUsageAnalyzer {
    func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    func sessionID(from file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(5).joined(separator: "-")
    }

    func sessionTreeSignature(for files: [URL]) -> SessionTreeSignature {
        SessionTreeSignature(
            files: files
                .compactMap(sessionCacheKey(for:))
                .sorted { $0.path < $1.path },
            stateDatabase: sessionCacheKey(for: dataSource.stateDatabase)
        )
    }

    func parseSession(file: URL, sessionID: String) -> [TokenEvent] {
        let cacheKey = sessionCacheKey(for: file)
        if let cacheKey {
            if let events = Self.sessionEventCache.events(for: file.path, key: cacheKey) {
                return events
            }
        }

        var events: [TokenEvent] = []
        var previousTotal: Int?
        var currentUserPrompt = ""
        var assistantFragments: [String] = []
        let forkReplayCutoff = forkedSessionReplayCutoff(for: file)
        streamSessionLines(from: file) { lineString in
            if let message = extractPayloadMessage(from: lineString, expectedType: "user_message") {
                currentUserPrompt = message
                assistantFragments.removeAll(keepingCapacity: true)
                return
            }

            if let message = extractPayloadMessage(from: lineString, expectedType: "agent_message") {
                assistantFragments.append(message)
                return
            }

            guard let usageLine = parseTokenUsageLine(lineString) else {
                return
            }

            if let forkReplayCutoff, usageLine.timestamp <= forkReplayCutoff {
                return
            }

            let totalTokens = usageLine.total?.totalTokens
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

        if let cacheKey {
            Self.sessionEventCache.store(events, for: file.path, key: cacheKey)
        }

        return events
    }

    private func forkedSessionReplayCutoff(for file: URL) -> Date? {
        guard let firstLine = readFirstLinePrefix(from: file),
              let timestamp = parseSessionMetaForkTimestamp(firstLine) else { return nil }
        return timestamp.addingTimeInterval(30)
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
        guard line.contains(#""payload""#),
              line.contains(expectedType),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == expectedType,
              let message = payload["message"] as? String else {
            return nil
        }
        let normalized = normalizeExcerptText(message)
        return normalized.isEmpty ? nil : normalized
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
        let size = attributes[.size] as? UInt64 ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SessionCacheKey(path: file.path, size: size, modifiedAt: modifiedAt)
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

    private func streamSessionLines(from file: URL, handleLine: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        var pending = Data()
        let newline = Data([0x0A])
        let tokenNeedle = Data(#""token_count""#.utf8)
        let userMessageNeedle = Data(#""user_message""#.utf8)
        let agentMessageNeedle = Data(#""agent_message""#.utf8)

        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            pending.append(data)

            var searchStart = pending.startIndex
            while let newlineRange = pending[searchStart...].range(of: newline) {
                let lineRange = searchStart..<newlineRange.lowerBound
                let lineData = pending[lineRange]
                if lineData.range(of: tokenNeedle) != nil
                    || lineData.range(of: userMessageNeedle) != nil
                    || lineData.range(of: agentMessageNeedle) != nil {
                    handleLine(String(decoding: lineData, as: UTF8.self))
                }
                searchStart = newlineRange.upperBound
            }

            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
        }

        if !pending.isEmpty,
           pending.range(of: tokenNeedle) != nil
            || pending.range(of: userMessageNeedle) != nil
            || pending.range(of: agentMessageNeedle) != nil {
            handleLine(String(decoding: pending, as: UTF8.self))
        }
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
    }
}
