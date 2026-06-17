import Foundation

enum RecentRateLimitDetector {
    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private struct LimitHit {
        let limitID: String
        let timestamp: Date
    }

    static func latestLimitID(
        codexHome: URL,
        fileLimit: Int = 24,
        tailBytes: UInt64 = 512 * 1024
    ) -> String? {
        let candidates = sessionCandidates(codexHome: codexHome)
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(max(1, fileLimit))

        return candidates
            .compactMap { latestLimitHit(in: $0.url, fallbackDate: $0.modifiedAt, tailBytes: tailBytes) }
            .max { $0.timestamp < $1.timestamp }?
            .limitID
    }

    private static func sessionCandidates(codexHome: URL) -> [Candidate] {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var candidates: [Candidate] = []
        let fileManager = FileManager.default

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate else {
                    continue
                }
                candidates.append(Candidate(url: url, modifiedAt: modifiedAt))
            }
        }

        return candidates
    }

    private static func latestLimitHit(in url: URL, fallbackDate: Date, tailBytes: UInt64) -> LimitHit? {
        guard let text = tailText(url: url, maxBytes: tailBytes) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"token_count\""),
                  line.contains("rate_limits"),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let rawLimitID = (rateLimits["limit_id"] as? String) ?? (rateLimits["limitId"] as? String) else {
                continue
            }

            let limitID = rawLimitID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limitID.isEmpty else { continue }
            return LimitHit(
                limitID: limitID,
                timestamp: parseTimestamp(object["timestamp"] as? String) ?? fallbackDate
            )
        }
        return nil
    }

    private static func tailText(url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
