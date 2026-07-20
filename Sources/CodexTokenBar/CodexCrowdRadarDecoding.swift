import Foundation

enum CodexCrowdRadarParser {
    private typealias JSONObject = [String: Any]
    private static let wrapperKeys = ["data", "result", "snapshot", "payload", "response", "body"]

    static func decode(tableData: Data?, leaderboardData: Data) throws -> CodexCrowdRadarSnapshot {
        let tableObject: Any?
        if let tableData {
            tableObject = try? JSONSerialization.jsonObject(with: tableData)
        } else {
            tableObject = nil
        }
        let leaderboardObject = try JSONSerialization.jsonObject(with: leaderboardData)
        return try decode(tableObject: tableObject, leaderboardObject: leaderboardObject)
    }

    static func decode(
        tableObject: Any?,
        leaderboardObject: Any
    ) throws -> CodexCrowdRadarSnapshot {
        let table = findPayload(
            tableObject,
            signalKeys: [
                "baselineGeneratedAt", "generatedAt", "updatedAt", "monitoredAt",
                "tasks", "taskRows", "taskList", "taskCount",
                "cells", "cellMap", "cellRows", "cellCount"
            ]
        )
        let leaderboard = findPayload(
            leaderboardObject,
            signalKeys: [
                "models", "rankings", "modelStats", "modelSummaries", "rows",
                "contributors", "volunteers", "contributorRows", "contributorCount", "volunteerCount",
                "pendingGrades", "pending", "pendingCount", "queuedGrades",
                "errorGrades", "errors", "errorCount", "failedGrades"
            ]
        )
        let models = parseModels(leaderboard)
        guard models.contains(where: { $0.graded > 0 }) else {
            throw CodexRadarReaderError.emptyPayload
        }
        return CodexCrowdRadarSnapshot(
            generatedAt: firstString(
                table,
                aliases: ["baselineGeneratedAt", "generatedAt", "updatedAt", "monitoredAt"]
            ) ?? firstString(
                leaderboard,
                aliases: ["generatedAt", "updatedAt", "monitoredAt"]
            ) ?? "",
            taskCount: firstCollectionCount(
                table,
                aliases: ["tasks", "taskRows", "taskList", "taskCount"]
            ) ?? firstCollectionCount(
                leaderboard,
                aliases: ["tasks", "taskRows", "taskList", "taskCount"]
            ) ?? 0,
            cellCount: firstCollectionCount(
                table,
                aliases: ["cells", "cellMap", "cellRows", "cellCount"]
            ) ?? 0,
            contributorCount: firstCollectionCount(
                leaderboard,
                aliases: [
                    "contributors", "volunteers", "contributorRows", "contributorCount", "volunteerCount"
                ]
            ) ?? 0,
            pendingGrades: firstInteger(
                leaderboard,
                aliases: ["pendingGrades", "pending", "pendingCount", "queuedGrades"]
            ) ?? 0,
            errorGrades: firstInteger(
                leaderboard,
                aliases: ["errorGrades", "errors", "errorCount", "failedGrades"]
            ) ?? 0,
            models: models
        )
    }

    private static func parseModels(_ leaderboard: JSONObject?) -> [CodexCrowdRadarModel] {
        let container = value(
            in: leaderboard,
            aliases: ["models", "rankings", "modelStats", "modelSummaries", "rows"]
        )
        if let rows = container as? [Any] {
            return rows.compactMap { parseModel($0, fallbackKey: "") }
        }
        guard let rows = object(container) else { return [] }
        return rows.keys.sorted().compactMap { key in
            parseModel(rows[key], fallbackKey: key)
        }
    }

    private static func parseModel(_ rawValue: Any?, fallbackKey: String) -> CodexCrowdRadarModel? {
        guard let row = object(rawValue) else { return nil }
        var model = firstString(
            row,
            aliases: ["model", "modelName", "name", "modelId", "modelKey"]
        ) ?? ""
        var effort = firstString(
            row,
            aliases: ["effort", "reasoningEffort", "reasoning", "level", "tier"]
        ) ?? ""
        fillModelIdentity(model: &model, effort: &effort, fallbackKey: fallbackKey)
        guard !model.isEmpty else { return nil }

        let taskStats = object(value(
            in: row,
            aliases: ["tasks", "taskResults", "results", "samplesByTask"]
        ))
        let derivedVotes = sumNestedIntegers(
            taskStats,
            aliases: ["votes", "graded", "count", "samples"]
        )
        let derivedPasses = sumNestedIntegers(
            taskStats,
            aliases: ["passVotes", "passed", "passes", "successes"]
        )
        let graded = firstInteger(
            row,
            aliases: [
                "graded", "gradedCount", "judged", "judgedCount", "sampleCount", "samples", "attempts"
            ]
        ) ?? derivedVotes
        let passed = firstInteger(
            row,
            aliases: ["passed", "passCount", "passedCount", "successes", "successCount"]
        ) ?? derivedPasses
        let directRate = rateValue(value(
            in: row,
            aliases: ["passRate", "successRate", "winRate", "rate"]
        ))
        let iq = numberValue(value(in: row, aliases: ["iq", "iqScore"]))
        let passRate: Double?
        if let directRate {
            passRate = directRate
        } else if let iq, (0...150).contains(iq) {
            passRate = iq / 150
        } else if graded > 0, passed >= 0, passed <= graded {
            passRate = Double(passed) / Double(graded)
        } else {
            passRate = nil
        }
        guard let passRate else { return nil }
        let cells = firstInteger(
            row,
            aliases: ["cells", "cellCount", "coveredCells", "taskCount", "coveredTasks"]
        ) ?? taskStats?.count ?? 0
        return CodexCrowdRadarModel(
            model: model,
            effort: effort,
            graded: max(0, graded),
            passed: max(0, passed),
            passRate: passRate,
            cells: max(0, cells)
        )
    }

    private static func fillModelIdentity(
        model: inout String,
        effort: inout String,
        fallbackKey: String
    ) {
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        effort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = model.isEmpty
            ? fallbackKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : model
        if effort.isEmpty,
           let separator = identity.lastIndex(where: { $0 == "|" || $0 == ":" }) {
            let next = identity.index(after: separator)
            if next < identity.endIndex {
                model = String(identity[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                effort = String(identity[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if model.isEmpty { model = identity }
        if effort.isEmpty {
            let lowercased = model.lowercased()
            for knownEffort in ["minimal", "medium", "xhigh", "ultra", "high", "low", "max"] {
                let suffix = "-\(knownEffort)"
                guard lowercased.hasSuffix(suffix) else { continue }
                effort = knownEffort
                model.removeLast(suffix.count)
                break
            }
        }
    }

    private static func findPayload(
        _ value: Any?,
        signalKeys: [String],
        depth: Int = 0
    ) -> JSONObject? {
        guard let root = object(value) else { return nil }
        if signalKeys.contains(where: { self.value(in: root, aliases: [$0]) != nil }) {
            return root
        }
        guard depth < 5 else { return root }
        for wrapper in wrapperKeys {
            guard let nested = self.value(in: root, aliases: [wrapper]),
                  let match = findPayload(nested, signalKeys: signalKeys, depth: depth + 1),
                  signalKeys.contains(where: { self.value(in: match, aliases: [$0]) != nil }) else {
                continue
            }
            return match
        }
        return root
    }

    private static func object(_ value: Any?) -> JSONObject? {
        value as? JSONObject
    }

    private static func value(in object: JSONObject?, aliases: [String]) -> Any? {
        guard let object else { return nil }
        for alias in aliases {
            let canonicalAlias = CodexRadarJSONKeyMatcher.canonical(alias)
            if let key = object.keys.first(where: {
                CodexRadarJSONKeyMatcher.canonical($0) == canonicalAlias
            }) {
                return object[key]
            }
        }
        return nil
    }

    private static func firstString(_ object: JSONObject?, aliases: [String]) -> String? {
        guard let string = value(in: object, aliases: aliases) as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        guard let string = value as? String else { return nil }
        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
        guard !normalized.isEmpty, let result = Double(normalized), result.isFinite else { return nil }
        return result
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = numberValue(value),
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private static func firstInteger(_ object: JSONObject?, aliases: [String]) -> Int? {
        integerValue(value(in: object, aliases: aliases))
    }

    private static func rateValue(_ value: Any?) -> Double? {
        guard let number = numberValue(value) else { return nil }
        let isPercent = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("%") == true
        let normalized = isPercent || number > 1 ? number / 100 : number
        return (0...1).contains(normalized) ? normalized : nil
    }

    private static func firstCollectionCount(_ object: JSONObject?, aliases: [String]) -> Int? {
        let value = value(in: object, aliases: aliases)
        if let array = value as? [Any] { return array.count }
        if let dictionary = self.object(value) { return dictionary.count }
        return integerValue(value)
    }

    private static func sumNestedIntegers(_ rows: JSONObject?, aliases: [String]) -> Int {
        rows?.values.reduce(into: 0) { total, value in
            total += firstInteger(object(value), aliases: aliases) ?? 0
        } ?? 0
    }
}
