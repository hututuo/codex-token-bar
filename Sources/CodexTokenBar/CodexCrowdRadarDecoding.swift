import Foundation

enum CodexCrowdRadarParser {
    private typealias JSONObject = [String: Any]
    private static let wrapperKeys = ["data", "result", "snapshot", "payload", "response", "body"]

    private struct TableAggregation {
        let realtimeModels: [CodexCrowdRadarModel]
        let recentModels: [CodexCrowdRadarModel]
        let latestGradedAt: String?
    }

    static func decode(tableData: Data?, leaderboardData: Data?) throws -> CodexCrowdRadarSnapshot {
        let tableObject: Any?
        if let tableData {
            tableObject = try? JSONSerialization.jsonObject(with: tableData)
        } else {
            tableObject = nil
        }
        let leaderboardObject: Any?
        if let leaderboardData {
            leaderboardObject = try? JSONSerialization.jsonObject(with: leaderboardData)
        } else {
            leaderboardObject = nil
        }
        return try decode(tableObject: tableObject, leaderboardObject: leaderboardObject)
    }

    static func decode(
        tableObject: Any?,
        leaderboardObject: Any?
    ) throws -> CodexCrowdRadarSnapshot {
        let table = findPayload(
            tableObject,
            signalKeys: [
                "baselineGeneratedAt", "generatedAt", "updatedAt", "monitoredAt", "sourceUpdatedAt",
                "tasks", "taskRows", "taskList", "taskCount",
                "cells", "cellMap", "cellRows", "cellCount"
            ]
        )
        let leaderboard = findPayload(
            leaderboardObject,
            signalKeys: [
                "models", "points", "rankings", "modelStats", "modelSummaries", "rows",
                "contributors", "volunteers", "contributorRows", "contributorCount", "volunteerCount",
                "pendingGrades", "pending", "pendingCount", "queuedGrades",
                "errorGrades", "errors", "errorCount", "failedGrades"
            ]
        )
        let leaderboardModels = parseModels(leaderboard)
        let tableAggregation = parseTableModels(table, leaderboardModels: leaderboardModels)
        let realtimeModels = tableAggregation.realtimeModels
        let recentModels = tableAggregation.recentModels.isEmpty
            ? leaderboardModels
            : tableAggregation.recentModels
        guard (realtimeModels + recentModels).contains(where: { $0.scoreSamples > 0 }) else {
            throw CodexRadarReaderError.emptyPayload
        }
        return CodexCrowdRadarSnapshot(
            generatedAt: tableAggregation.latestGradedAt ?? firstString(
                table,
                aliases: ["baselineGeneratedAt", "generatedAt", "updatedAt", "monitoredAt", "sourceUpdatedAt"]
            ) ?? firstString(
                leaderboard,
                aliases: ["generatedAt", "updatedAt", "monitoredAt", "sourceUpdatedAt"]
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
            models: realtimeModels,
            recentModels: recentModels,
            realtimeAvailable: !realtimeModels.isEmpty
        )
    }

    private static func parseModels(_ leaderboard: JSONObject?) -> [CodexCrowdRadarModel] {
        let container = value(
            in: leaderboard,
            aliases: ["models", "points", "rankings", "modelStats", "modelSummaries", "rows"]
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
                "graded", "gradedCount", "judged", "judgedCount", "sampleCount", "samples", "attempts", "validTasks"
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
            aliases: ["cells", "cellCount", "coveredCells", "taskCount", "coveredTasks", "validTasks"]
        ) ?? taskStats?.count ?? 0
        let scorePassed = firstInteger(
            row,
            aliases: ["cellsPassed", "passedCells", "tasksPassed", "passedTasks"]
        ) ?? (cells > 0 ? Int((passRate * Double(cells)).rounded()) : passed)
        let scoreSamples = cells > 0 ? cells : graded
        return CodexCrowdRadarModel(
            model: model,
            effort: effort,
            graded: max(0, graded),
            passed: max(0, passed),
            passRate: passRate,
            cells: max(0, cells),
            scorePassed: max(0, scorePassed),
            scoreSamples: max(0, scoreSamples),
            latestGradedAt: firstString(
                row,
                aliases: ["latestGradedAt", "gradedAt", "updatedAt", "monitoredAt"]
            )
        )
    }

    private static func parseTableModels(
        _ table: JSONObject?,
        leaderboardModels: [CodexCrowdRadarModel]
    ) -> TableAggregation {
        let explicitCombos = collectionRows(value(in: table, aliases: ["combos", "modelCombos", "models"]))
        let combos: [(key: String, value: Any)]
        if let explicitCombos, !explicitCombos.isEmpty {
            combos = explicitCombos
        } else {
            combos = leaderboardModels.enumerated().map { index, model in
                (
                    key: String(index),
                    value: ["model": model.model, "effort": model.effort] as JSONObject
                )
            }
        }
        guard let tasks = collectionRows(value(in: table, aliases: ["tasks", "taskRows", "taskList"])),
              let cells = object(value(in: table, aliases: ["cells", "cellMap", "cellRows"])),
              !combos.isEmpty,
              !tasks.isEmpty,
              !cells.isEmpty else {
            return TableAggregation(realtimeModels: [], recentModels: [], latestGradedAt: nil)
        }

        let leaderboardByIdentity = Dictionary(
            leaderboardModels.map { (modelIdentity(model: $0.model, effort: $0.effort), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var realtimeModels: [CodexCrowdRadarModel] = []
        var recentModels: [CodexCrowdRadarModel] = []
        var globalLatestGradedAt: String?

        for comboEntry in combos {
            guard let combo = object(comboEntry.value) else { continue }
            var model = firstString(
                combo,
                aliases: ["model", "modelName", "name", "modelId", "modelKey"]
            ) ?? ""
            var effort = firstString(
                combo,
                aliases: ["effort", "reasoningEffort", "reasoning", "level", "tier"]
            ) ?? ""
            fillModelIdentity(model: &model, effort: &effort, fallbackKey: comboEntry.key)
            guard !model.isEmpty, !effort.isEmpty else { continue }

            var realtimePassed = 0
            var realtimeSamples = 0
            var recentPassed = 0
            var recentSamples = 0
            var recentCells = 0
            var latestGradedAt: String?

            for taskEntry in tasks {
                guard let taskID = taskIdentifier(taskEntry) else {
                    continue
                }
                let cellKey = "\(taskID)|\(model)|\(effort)"
                guard let cell = object(cells[cellKey]) else { continue }

                if let runners = value(
                    in: cell,
                    aliases: ["ranBy", "runners", "runs", "results"]
                ) as? [Any],
                   let runner = runners.first.flatMap(object) {
                    if let passed = booleanValue(value(in: runner, aliases: ["passed", "success", "ok"])) {
                        realtimeSamples += 1
                        if passed { realtimePassed += 1 }
                    }
                    if let gradedAt = firstString(
                        runner,
                        aliases: ["gradedAt", "judgedAt", "updatedAt", "completedAt"]
                    ) ?? firstString(
                        cell,
                        aliases: ["lastGradedAt", "gradedAt", "updatedAt"]
                    ) {
                        latestGradedAt = newestTimestamp(latestGradedAt, gradedAt)
                        globalLatestGradedAt = newestTimestamp(globalLatestGradedAt, gradedAt)
                    }
                }

                if let sampleCount = firstInteger(
                    cell,
                    aliases: ["n", "recentSamples", "sampleCount", "samples"]
                ),
                   let passCount = firstInteger(
                    cell,
                    aliases: ["p", "recentPassed", "passCount", "passes"]
                   ),
                   sampleCount > 0,
                   passCount >= 0,
                   passCount <= sampleCount {
                    recentSamples += sampleCount
                    recentPassed += passCount
                    recentCells += 1
                }
            }

            let metadata = leaderboardByIdentity[modelIdentity(model: model, effort: effort)]
            if realtimeSamples > 0 {
                realtimeModels.append(makeTableModel(
                    model: model,
                    effort: effort,
                    scorePassed: realtimePassed,
                    scoreSamples: realtimeSamples,
                    coveredCells: realtimeSamples,
                    latestGradedAt: latestGradedAt,
                    metadata: metadata
                ))
            }
            if recentSamples > 0 {
                recentModels.append(makeTableModel(
                    model: model,
                    effort: effort,
                    scorePassed: recentPassed,
                    scoreSamples: recentSamples,
                    coveredCells: recentCells,
                    latestGradedAt: latestGradedAt,
                    metadata: metadata
                ))
            }
        }

        return TableAggregation(
            realtimeModels: realtimeModels,
            recentModels: recentModels,
            latestGradedAt: globalLatestGradedAt
        )
    }

    private static func makeTableModel(
        model: String,
        effort: String,
        scorePassed: Int,
        scoreSamples: Int,
        coveredCells: Int,
        latestGradedAt: String?,
        metadata: CodexCrowdRadarModel?
    ) -> CodexCrowdRadarModel {
        CodexCrowdRadarModel(
            model: model,
            effort: effort,
            graded: metadata?.graded ?? scoreSamples,
            passed: metadata?.passed ?? scorePassed,
            passRate: Double(scorePassed) / Double(scoreSamples),
            cells: max(metadata?.cells ?? 0, coveredCells),
            scorePassed: scorePassed,
            scoreSamples: scoreSamples,
            latestGradedAt: latestGradedAt
        )
    }

    private static func collectionRows(_ value: Any?) -> [(key: String, value: Any)]? {
        if let rows = value as? [Any] {
            return rows.enumerated().map { (String($0.offset), $0.element) }
        }
        guard let rows = object(value) else { return nil }
        return rows.keys.sorted().compactMap { key in
            rows[key].map { (key, $0) }
        }
    }

    private static func identifierValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return nonEmpty(value)
        }
        if let integer = integerValue(value) {
            return String(integer)
        }
        return nil
    }

    private static func taskIdentifier(
        _ entry: (key: String, value: Any)
    ) -> String? {
        if let task = object(entry.value),
           let identifier = identifierValue(
               value(in: task, aliases: ["id", "taskId", "taskKey", "name"])
           ) {
            return identifier
        }
        return identifierValue(entry.value) ?? nonEmpty(entry.key)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        guard let value = value as? String else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private static func modelIdentity(model: String, effort: String) -> String {
        "\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func newestTimestamp(_ current: String?, _ candidate: String) -> String {
        guard let current else { return candidate }
        // The public table emits normalized ISO-8601 timestamps. Lexicographic
        // comparison therefore preserves chronological order without sharing a
        // mutable DateFormatter across concurrent refreshes.
        return candidate > current ? candidate : current
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
        if let number = value as? NSNumber {
            // JSONSerialization bridges numeric 0/1 so that `value is Bool`
            // also succeeds. objCType keeps real JSON booleans (`c`) distinct
            // from integer 0/1 (`q`), which are valid p/n counters.
            guard String(cString: number.objCType) != "c" else { return nil }
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
