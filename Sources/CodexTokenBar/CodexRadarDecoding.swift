import Foundation

extension JSONDecoder {
    static var codexRadar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            guard let sourceKey = codingPath.last else {
                return CodexRadarFlexibleCodingKey(stringValue: "")
            }
            return CodexRadarFlexibleCodingKey(
                stringValue: CodexRadarJSONKeyMatcher.preferredKey(for: sourceKey.stringValue)
            )
        }
        return decoder
    }
}

/// Matches spelling-only JSON key changes without guessing at unrelated semantics.
/// Variants may differ by case, `_`, `-`, spaces, or acronym spelling
/// (`24h`/`24H`, `20x`/`20X`).
enum CodexRadarJSONKeyMatcher {
    private static let preferredKeys: [String] = [
        "schemaVersion", "service", "monitoredAt", "timezone", "windowOpen", "status",
        "recommendedAction", "window", "prediction", "tiboPresence", "recentWindows", "links",
        "modelIq", "codexEnvironment", "data", "result", "snapshot", "payload",
        "open", "action", "message", "title", "scope",
        "openedAt", "closedAt", "countdownDeadline", "sourceUrl", "level", "probability24H", "probability48H",
        "expectedWindow", "summary", "summaryEn", "positiveSignals", "negativeSignals", "updatedAt",
        "mode", "locationLabelZh", "locationLabelEn", "probability", "confidence",
        "evidenceSummaryZh", "evidenceSummaryEn", "sourceUrls", "shouldDisplay", "safetyNoteZh",
        "safetyNoteEn", "observedAt", "staleAt", "observationsConsidered", "html", "rss",
        "latest", "recentDays", "comparisons", "quotaCalibration", "quotaRadar", "quotaCheck",
        "label", "model", "reasoningEffort", "date", "score", "passed", "tasks", "invalid",
        "validTasks", "totalTokens", "inputTokens", "cachedInputTokens", "outputTokens",
        "wallSeconds", "wallTimeHuman", "costUsd", "source", "primaryWindow", "globalConcurrency",
        "checkedAtBefore", "checkedAtAfter", "basisDate", "basisWindow", "basisWindowLabel",
        "adjustedDelta", "rawDelta", "offset", "rate", "endpoint", "sourceKind",
        "fiveHourPolicy", "sevenDayPolicy", "rows", "trend", "tier", "basis", "fiveH", "sevenD",
        "fiveH20X", "sevenD20X", "fiveH5X", "fiveHPlus", "checkedAt", "planType",
        "rateLimitResetCreditsAvailableCount", "limitReached", "allowed", "type",
        "statusIncidents24H", "officialUpdates24H", "communityMentions24H",
        "issueOrLimitAnomalies24H", "complaintPressure", "resetCard", "officialNews",
        "statusIncidents", "complaintExamples", "roleCounts", "note", "titleZh", "summaryZh",
        "account", "createdAt", "semanticRole", "url", "text", "predictionRelevance",
        "baselineGeneratedAt", "cells", "models", "contributors", "pendingGrades", "errorGrades",
        "effort", "graded", "passRate"
    ]

    private static let preferredByCanonical: [String: String] = {
        var result: [String: String] = [:]
        for key in preferredKeys {
            result[canonical(key)] = key
        }
        return result
    }()

    static func preferredKey(for rawKey: String) -> String {
        if let preferred = preferredByCanonical[canonical(rawKey)] {
            return preferred
        }
        return lowerCamelKey(rawKey)
    }

    static func canonical(_ key: String) -> String {
        key.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func lowerCamelKey(_ key: String) -> String {
        let parts = key.split { character in
            character.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
        }
        guard parts.count > 1, let first = parts.first else { return key }
        return first.lowercased() + parts.dropFirst().map { part in
            guard let head = part.first else { return "" }
            return String(head).uppercased() + part.dropFirst()
        }.joined()
    }
}

struct CodexRadarFlexibleCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct CodexRadarLossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                _ = try? container.decode(CodexRadarDiscardValue.self)
            }
        }
        elements = decoded
    }
}

struct CodexRadarLossyDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodexRadarFlexibleCodingKey.self)
        var decoded: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                decoded[key.stringValue] = value
            }
        }
        values = decoded
    }
}

private struct CodexRadarDiscardValue: Decodable {}

extension KeyedDecodingContainer {
    func codexRadarDecodeSafely<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            return nil
        }
    }

    func codexRadarString(forKey key: Key) -> String? {
        if let value = codexRadarDecodeSafely(String.self, forKey: key) {
            return value
        }
        return nil
    }

    func codexRadarDouble(forKey key: Key) -> Double? {
        if let value = codexRadarDecodeSafely(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = codexRadarDecodeSafely(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = codexRadarString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let value = Double(raw),
           value.isFinite {
            return value
        }
        return nil
    }

    func codexRadarInt(forKey key: Key) -> Int? {
        if let value = codexRadarDecodeSafely(Int.self, forKey: key) {
            return value
        }
        if let value = codexRadarDecodeSafely(Double.self, forKey: key),
           value.isFinite,
           value.rounded() == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return Int(value)
        }
        if let raw = codexRadarString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let value = Int(raw) {
            return value
        }
        return nil
    }

    func codexRadarBool(forKey key: Key) -> Bool? {
        if let value = codexRadarDecodeSafely(Bool.self, forKey: key) {
            return value
        }
        if let value = codexRadarInt(forKey: key), value == 0 || value == 1 {
            return value == 1
        }
        switch codexRadarString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on":
            return true
        case "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    func codexRadarLossyArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key
    ) -> [Element] {
        codexRadarDecodeSafely(CodexRadarLossyArray<Element>.self, forKey: key)?.elements ?? []
    }

    func codexRadarLossyDictionary<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> [String: Value] {
        codexRadarDecodeSafely(CodexRadarLossyDictionary<Value>.self, forKey: key)?.values ?? [:]
    }
}
