import AppKit
import Foundation

private struct ProviderSyncReport {
    var codexHome: URL
    var targetProvider: String
    var providerSource: String
    var sessionFiles: [URL]
    var sessionProviders: [String: Int]
    var invalidSessionFiles: Int
    var sqliteProviders: [ProviderSyncSQLiteProvider]
    var sqliteRowsToRepair: Int
    var sqliteIntegrity: String
    var latestThreadID: String?
    var sessionIndexIDs: Set<String>
    var sessionIndexRows: Int
    var workspaceIssues: [ProviderSyncWorkspaceIssue]
    var visibilitySummary: ProviderSyncVisibilitySummary
    var codexRunning: Bool
}

private struct ProviderSyncSQLiteProvider {
    var provider: String
    var archived: Int
    var count: Int
}

private struct ProviderSyncThreadIndexRow {
    var id: String
    var title: String
    var updatedAtMilliseconds: Int64
}

private struct ProviderSyncSessionTimestamp {
    var id: String
    var updatedAtMilliseconds: Int64
    var fileURL: URL
}

private struct ProviderSyncThreadTimestampRow {
    var id: String
    var updatedAtMilliseconds: Int64
}

private struct ProviderSyncSessionIndexLines {
    var lines: [String]
    var ids: Set<String>
    var rows: Int
}

private struct ProviderSyncSQLiteThreadColumns {
    var modelProvider: Bool
    var hasUserEvent: Bool
    var firstUserMessage: Bool
    var threadSource: Bool
    var title: Bool
    var preview: Bool
    var source: Bool
    var cwd: Bool
    var archived: Bool
    var updatedAt: Bool
    var updatedAtMilliseconds: Bool
}

final class ProviderSyncEngine {
    private let fileManager = FileManager.default

    func scan(codexHome: URL, includeArchivedSessions: Bool) throws -> ProviderSyncSnapshot {
        let report = try makeReport(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions, targetProviderOverride: nil)
        return snapshot(from: report, status: "扫描完成")
    }

    func verify(codexHome: URL, includeArchivedSessions: Bool, targetProviderOverride: String?) throws -> ProviderSyncSnapshot {
        let report = try makeReport(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions, targetProviderOverride: targetProviderOverride)
        let allSessionsMatch = report.sessionProviders.keys.allSatisfy { $0 == report.targetProvider }
        let allSQLiteMatch = report.sqliteProviders.allSatisfy { $0.provider == report.targetProvider }
        let status = allSessionsMatch
            && allSQLiteMatch
            && report.sqliteRowsToRepair == 0
            && report.workspaceIssues.isEmpty
            && report.sqliteIntegrity == "ok"
            ? "验证通过"
            : "验证完成：仍有历史或前端工作区状态未同步"
        return snapshot(from: report, status: status)
    }

    func sync(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?,
        dryRunOnly: Bool
    ) throws -> ProviderSyncSnapshot {
        let initial = try makeReport(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions, targetProviderOverride: targetProviderOverride)
        let backupPath = try createBackup(codexHome: codexHome, sessionFiles: initial.sessionFiles, targetProvider: initial.targetProvider)

        var changedSessionFiles = 0
        var sqliteRowsChanged = 0
        if !dryRunOnly {
            do {
                for file in initial.sessionFiles {
                    if try rewriteSessionMetaProvider(file: file, targetProvider: initial.targetProvider) {
                        changedSessionFiles += 1
                    }
                }
                sqliteRowsChanged = try updateSQLite(codexHome: codexHome, targetProvider: initial.targetProvider)
                sqliteRowsChanged += try repairSQLiteThreadTimestamps(codexHome: codexHome, sessionFiles: initial.sessionFiles)
                _ = try reconcileSessionIndex(codexHome: codexHome)
                _ = try reconcileWorkspaceOrder(codexHome: codexHome)
            } catch {
                do {
                    try restoreBackup(backupPath, codexHome: codexHome)
                } catch {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 500,
                        userInfo: [
                            NSLocalizedDescriptionKey: "同步失败，且自动回滚失败：\(error.localizedDescription)"
                        ]
                    )
                }
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [
                        NSLocalizedDescriptionKey: "同步失败，已自动回滚：\(error.localizedDescription)"
                    ]
                )
            }
        }

        let verified = try makeReport(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions, targetProviderOverride: targetProviderOverride)
        let allSessionsMatch = verified.sessionProviders.keys.allSatisfy { $0 == verified.targetProvider }
        let allSQLiteMatch = verified.sqliteProviders.allSatisfy { $0.provider == verified.targetProvider }
        let verifiedStatus = allSessionsMatch
            && allSQLiteMatch
            && verified.sqliteRowsToRepair == 0
            && verified.workspaceIssues.isEmpty
            && verified.sqliteIntegrity == "ok"
            ? "同步完成并已验证"
            : "同步完成，但仍有历史或前端工作区状态未同步"
        var next = snapshot(from: verified, status: dryRunOnly ? "Dry run 完成，已创建备份但未改历史" : verifiedStatus)
        next.changedSessionFiles = changedSessionFiles
        next.sqliteRowsChanged = sqliteRowsChanged
        next.lastBackupPath = backupPath.path
        return next
    }

    func rollbackLatest(codexHome: URL) throws -> ProviderSyncSnapshot {
        let backup = try latestBackupDirectory(for: codexHome)
        return try rollback(codexHome: codexHome, backup: backup, status: "已从最近备份回滚")
    }

    func rollback(codexHome: URL, backupPath: String) throws -> ProviderSyncSnapshot {
        try rollback(codexHome: codexHome, backup: URL(fileURLWithPath: backupPath), status: "已从所选备份回滚")
    }

    private func rollback(codexHome: URL, backup: URL, status: String) throws -> ProviderSyncSnapshot {
        try restoreBackup(backup, codexHome: codexHome)
        let report = try makeReport(codexHome: codexHome, includeArchivedSessions: true, targetProviderOverride: nil)
        var next = snapshot(from: report, status: status)
        next.lastBackupPath = backup.path
        return next
    }

    private func makeReport(codexHome: URL, includeArchivedSessions: Bool, targetProviderOverride: String?) throws -> ProviderSyncReport {
        let sessionFiles = findSessionFiles(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions)
        var sessionProviders: [String: Int] = [:]
        var invalidSessionFiles = 0
        for file in sessionFiles {
            guard let provider = try readSessionProvider(file: file) else {
                invalidSessionFiles += 1
                continue
            }
            sessionProviders[provider, default: 0] += 1
        }

        let sqliteProviders = try readSQLiteProviders(codexHome: codexHome)
        let latestSQLite = try latestSQLiteProvider(codexHome: codexHome)
        let configProvider = try configProvider(codexHome: codexHome)
        let targetProvider = targetProviderOverride
            ?? configProvider
            ?? "openai"
        let providerSource: String
        if targetProviderOverride != nil {
            providerSource = "手动指定"
        } else if configProvider != nil {
            providerSource = "config.toml"
        } else {
            providerSource = "默认 openai，config.toml 未设置"
        }

        let indexIDs = try readSessionIndexIDs(codexHome: codexHome)
        let sqliteRowsToRepair = try countSQLiteRowsToRepair(codexHome: codexHome, targetProvider: targetProvider)
        let workspaceIssues = try readWorkspaceOrderIssues(codexHome: codexHome)
        let visibilitySummary = try readVisibilitySummary(codexHome: codexHome)
        return ProviderSyncReport(
            codexHome: codexHome,
            targetProvider: targetProvider,
            providerSource: providerSource,
            sessionFiles: sessionFiles,
            sessionProviders: sessionProviders,
            invalidSessionFiles: invalidSessionFiles,
            sqliteProviders: sqliteProviders,
            sqliteRowsToRepair: sqliteRowsToRepair,
            sqliteIntegrity: try sqliteIntegrity(codexHome: codexHome),
            latestThreadID: latestSQLite.threadID,
            sessionIndexIDs: indexIDs.ids,
            sessionIndexRows: indexIDs.rows,
            workspaceIssues: workspaceIssues,
            visibilitySummary: visibilitySummary,
            codexRunning: isCodexRunning()
        )
    }

    private func snapshot(from report: ProviderSyncReport, status: String) -> ProviderSyncSnapshot {
        ProviderSyncSnapshot(
            codexHome: CodexDataSource(codexHome: report.codexHome, origin: .defaultHome).displayPath,
            detectedProvider: report.targetProvider,
            providerSource: report.providerSource,
            sessionFilesFound: report.sessionFiles.count,
            sessionProviders: report.sessionProviders
                .map { ProviderSyncProviderCount(provider: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.provider < $1.provider : $0.count > $1.count },
            sqliteProviders: report.sqliteProviders
                .map { ProviderSyncSQLiteCount(provider: $0.provider, archived: $0.archived, count: $0.count) }
                .sorted { lhs, rhs in
                    if lhs.archived != rhs.archived { return lhs.archived < rhs.archived }
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.provider < rhs.provider
                },
            invalidSessionFiles: report.invalidSessionFiles,
            sqliteRowsToRepair: report.sqliteRowsToRepair,
            sqliteIntegrity: report.sqliteIntegrity,
            sessionIndexCurrentThreadPresent: report.latestThreadID.map { report.sessionIndexIDs.contains($0) } ?? false,
            sessionIndexRows: report.sessionIndexRows,
            workspaceOrderMissing: report.workspaceIssues.count,
            workspaceIssues: report.workspaceIssues,
            visibilitySummary: report.visibilitySummary,
            codexRunning: report.codexRunning,
            backupRecords: backupRecords(for: report.codexHome),
            status: report.codexRunning ? "\(status)，建议退出 Codex 后执行同步" : status,
            isWorking: false
        )
    }

    private func configProvider(codexHome: URL) throws -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard fileManager.fileExists(atPath: config.path) else { return nil }
        let text = try String(contentsOf: config, encoding: .utf8)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let range = line.range(of: #"^\s*model_provider\s*=\s*"([^"]+)""#, options: .regularExpression) else { continue }
            let match = String(line[range])
            if let valueRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                return String(match[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func findSessionFiles(codexHome: URL, includeArchivedSessions: Bool) -> [URL] {
        var roots = [codexHome.appendingPathComponent("sessions")]
        if includeArchivedSessions {
            roots.append(codexHome.appendingPathComponent("archived_sessions"))
        }
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                    files.append(file)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func newestSessionProvider(in files: [URL]) throws -> (provider: String?, file: URL?) {
        let sorted = files.sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in sorted {
            if let provider = try readSessionProvider(file: file) {
                return (provider, file)
            }
        }
        return (nil, nil)
    }

    private func readSessionProvider(file: URL) throws -> String? {
        guard let object = try readFirstLineJSON(file: file),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        return (payload["model_provider"] as? String) ?? "(missing)"
    }

    private func readFirstLineJSON(file: URL) throws -> [String: Any]? {
        guard let firstLine = try readFirstLineData(file: file), !firstLine.isEmpty else { return nil }
        let value = try JSONSerialization.jsonObject(with: firstLine, options: [])
        return value as? [String: Any]
    }

    private func readFirstLineData(file: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else {
                return buffer.isEmpty ? nil : buffer
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[..<newline])
                return buffer
            }
            buffer.append(chunk)
        }
    }

    private func rewriteSessionMetaProvider(file: URL, targetProvider: String) throws -> Bool {
        let originalModificationDate = modificationDate(of: file)
        let data = try Data(contentsOf: file)
        guard let parts = firstLineParts(in: data), !parts.line.isEmpty else { return false }

        guard var object = try JSONSerialization.jsonObject(with: parts.line, options: []) as? [String: Any],
              object["type"] as? String == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return false
        }
        let currentProvider = payload["model_provider"] as? String
        guard currentProvider != targetProvider else { return false }

        payload["model_provider"] = targetProvider
        object["payload"] = payload
        let updatedLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var output = Data()
        output.append(updatedLine)
        output.append(parts.separator)
        output.append(parts.rest)
        try output.write(to: file, options: [.atomic])
        restoreModificationDate(originalModificationDate, for: file)
        return true
    }

    private func firstLineParts(in data: Data) -> (line: Data, separator: Data, rest: Data)? {
        guard !data.isEmpty else { return nil }
        guard let newline = data.firstIndex(of: 0x0A) else {
            return (data, Data(), Data())
        }

        let lineEnd: Data.Index
        let separatorStart: Data.Index
        if newline > data.startIndex {
            let previous = data.index(before: newline)
            if data[previous] == 0x0D {
                lineEnd = previous
                separatorStart = previous
            } else {
                lineEnd = newline
                separatorStart = newline
            }
        } else {
            lineEnd = newline
            separatorStart = newline
        }

        let restStart = data.index(after: newline)
        return (
            Data(data[data.startIndex..<lineEnd]),
            Data(data[separatorStart..<restStart]),
            Data(data[restStart..<data.endIndex])
        )
    }

    private func readSQLiteProviders(codexHome: URL) throws -> [ProviderSyncSQLiteProvider] {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return [] }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database),
                  columns.modelProvider else {
                return []
            }
            let archivedExpression = columns.archived ? "archived" : "0"
            return try queryRows(
                database: database,
                sql: """
                SELECT model_provider, \(archivedExpression), COUNT(*)
                FROM threads
                GROUP BY model_provider, \(archivedExpression)
                ORDER BY \(archivedExpression) ASC, COUNT(*) DESC;
                """
            ) { statement in
                ProviderSyncSQLiteProvider(
                    provider: sqliteText(statement, 0) ?? "(missing)",
                    archived: Int(sqliteInt64(statement, 1)),
                    count: Int(sqliteInt64(statement, 2))
                )
            }
        }
    }

    private func latestSQLiteProvider(codexHome: URL) throws -> (provider: String?, threadID: String?) {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return (nil, nil) }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return (nil, nil)
            }
            let providerExpression = columns.modelProvider ? "model_provider" : "NULL"
            let archivedFilter = columns.archived ? "WHERE archived = 0" : ""
            let updatedExpression = sqliteUpdatedAtMillisecondsExpression(columns: columns)
            return try queryRows(
                database: database,
                sql: """
                SELECT \(providerExpression), id
                FROM threads
                \(archivedFilter)
                ORDER BY \(updatedExpression) DESC
                LIMIT 1;
                """
            ) { statement in
                (sqliteText(statement, 0), sqliteText(statement, 1))
            }.first ?? (nil, nil)
        }
    }

    private func updateSQLite(codexHome: URL, targetProvider: String) throws -> Int {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: false) { database in
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            guard let columns = try readThreadsTableColumns(database: database),
                  let whereClause = threadsRepairWhereClause(columns: columns),
                  let setClause = threadsRepairSetClause(columns: columns) else {
                return 0
            }

            let values = columns.modelProvider ? [targetProvider] : []
            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            let changed: Int
            do {
                changed = try executeBoundUpdate(
                    database: database,
                    sql: "UPDATE threads SET \(setClause) WHERE \(whereClause);",
                    values: values
                )
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            return changed
        }
    }

    private func countSQLiteRowsToRepair(codexHome: URL, targetProvider: String) throws -> Int {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database),
                  let whereClause = threadsRepairWhereClause(columns: columns) else {
                return 0
            }
            let values = columns.modelProvider ? [targetProvider] : []
            return try queryBoundRows(
                database: database,
                sql: "SELECT COUNT(*) FROM threads WHERE \(whereClause);",
                values: values
            ) { statement in
                Int(sqliteInt64(statement, 0))
            }.first ?? 0
        }
    }

    private func repairSQLiteThreadTimestamps(codexHome: URL, sessionFiles: [URL]) throws -> Int {
        var timestampsByID: [String: ProviderSyncSessionTimestamp] = [:]
        for timestamp in try sessionFiles.compactMap({ try readSessionTimestamp(file: $0) }) {
            if let current = timestampsByID[timestamp.id],
               current.updatedAtMilliseconds >= timestamp.updatedAtMilliseconds {
                continue
            }
            timestampsByID[timestamp.id] = timestamp
        }
        guard !timestampsByID.isEmpty else { return 0 }

        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: false) { database in
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            guard let columns = try readThreadsTableColumns(database: database),
                  columns.updatedAt || columns.updatedAtMilliseconds else {
                return 0
            }

            let rows = try readSQLiteThreadTimestampRows(database: database, columns: columns)
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let collisionGroups = Dictionary(grouping: rows) { $0.updatedAtMilliseconds / 1_000 }
                .filter { second, rows in second > 0 && rows.count >= 4 }
            guard !collisionGroups.isEmpty else { return 0 }

            var repairTargets: [ProviderSyncSessionTimestamp] = []
            for (second, group) in collisionGroups {
                let sorted = group.sorted { lhs, rhs in
                    let lhsActual = timestampsByID[lhs.id]?.updatedAtMilliseconds ?? lhs.updatedAtMilliseconds
                    let rhsActual = timestampsByID[rhs.id]?.updatedAtMilliseconds ?? rhs.updatedAtMilliseconds
                    if lhsActual != rhsActual {
                        return lhsActual > rhsActual
                    }
                    return lhs.id < rhs.id
                }

                for (offset, row) in sorted.enumerated() {
                    guard let timestamp = timestampsByID[row.id] else { continue }
                    let target = (second - Int64(offset)) * 1_000
                    repairTargets.append(ProviderSyncSessionTimestamp(
                        id: row.id,
                        updatedAtMilliseconds: target,
                        fileURL: timestamp.fileURL
                    ))
                }
            }

            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var changed = 0
            do {
                for timestamp in repairTargets {
                    changed += try executeTimestampUpdate(database: database, columns: columns, timestamp: timestamp)
                }
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            changed += try repairSessionFileModificationDates(
                sessionTimestamps: Array(timestampsByID.values),
                rowsByID: rowsByID,
                repairTargets: repairTargets,
                collisionSeconds: Set(collisionGroups.keys)
            )
            return changed
        }
    }

    private func readSessionTimestamp(file: URL) throws -> ProviderSyncSessionTimestamp? {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let firstLine = lines.next(),
              let firstData = String(firstLine).data(using: .utf8),
              let firstObject = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any],
              firstObject["type"] as? String == "session_meta",
              let payload = firstObject["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              !id.isEmpty else {
            return nil
        }

        var latest = eventTimestampMilliseconds(firstObject) ?? 0
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = eventTimestampMilliseconds(object) else {
                continue
            }
            latest = max(latest, timestamp)
        }

        return latest > 0 ? ProviderSyncSessionTimestamp(id: id, updatedAtMilliseconds: latest, fileURL: file) : nil
    }

    private func readSQLiteThreadTimestampRows(
        database: SQLiteDatabaseConnection,
        columns: ProviderSyncSQLiteThreadColumns
    ) throws -> [ProviderSyncThreadTimestampRow] {
        let updatedExpression = sqliteUpdatedAtMillisecondsExpression(columns: columns)
        return try queryRows(
            database: database,
            sql: """
            SELECT id, \(updatedExpression)
            FROM threads
            WHERE COALESCE(id, '') <> '';
            """
        ) { statement in
            ProviderSyncThreadTimestampRow(
                id: sqliteText(statement, 0) ?? "",
                updatedAtMilliseconds: sqliteInt64(statement, 1)
            )
        }.filter { !$0.id.isEmpty }
    }

    private func repairSessionFileModificationDates(
        sessionTimestamps: [ProviderSyncSessionTimestamp],
        rowsByID: [String: ProviderSyncThreadTimestampRow],
        repairTargets: [ProviderSyncSessionTimestamp],
        collisionSeconds: Set<Int64>
    ) throws -> Int {
        let targetByID = Dictionary(uniqueKeysWithValues: repairTargets.map { ($0.id, $0.updatedAtMilliseconds) })
        var changed = 0
        for timestamp in sessionTimestamps {
            let attributes = try fileManager.attributesOfItem(atPath: timestamp.fileURL.path)
            guard let modificationDate = attributes[.modificationDate] as? Date else { continue }

            let currentMilliseconds = Int64(modificationDate.timeIntervalSince1970 * 1_000)
            let currentSecond = currentMilliseconds / 1_000
            var targetMilliseconds = targetByID[timestamp.id]
            if targetMilliseconds == nil,
               isCollisionSecond(currentSecond, collisionSeconds: collisionSeconds),
               let row = rowsByID[timestamp.id] {
                targetMilliseconds = row.updatedAtMilliseconds
            }

            guard let targetMilliseconds,
                  abs(currentMilliseconds - targetMilliseconds) >= 500 else {
                continue
            }

            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(targetMilliseconds) / 1_000)],
                ofItemAtPath: timestamp.fileURL.path
            )
            changed += 1
        }
        return changed
    }

    private func isCollisionSecond(_ second: Int64, collisionSeconds: Set<Int64>) -> Bool {
        collisionSeconds.contains(second)
            || collisionSeconds.contains(second - 1)
            || collisionSeconds.contains(second + 1)
    }

    private func eventTimestampMilliseconds(_ object: [String: Any]) -> Int64? {
        let keys = ["timestamp", "time", "created_at", "updated_at", "createdAt", "updatedAt"]
        for key in keys {
            if let milliseconds = timestampMilliseconds(from: object[key]) {
                return milliseconds
            }
        }
        if let payload = object["payload"] as? [String: Any] {
            for key in keys {
                if let milliseconds = timestampMilliseconds(from: payload[key]) {
                    return milliseconds
                }
            }
        }
        return nil
    }

    private func timestampMilliseconds(from value: Any?) -> Int64? {
        if let value = value as? String {
            let parsed = parseISO8601Milliseconds(value)
            return parsed > 0 ? parsed : nil
        }
        if let value = value as? Int64 {
            return normalizeTimestampMilliseconds(value)
        }
        if let value = value as? Int {
            return normalizeTimestampMilliseconds(Int64(value))
        }
        if let value = value as? Double, value.isFinite {
            return normalizeTimestampMilliseconds(Int64(value))
        }
        return nil
    }

    private func normalizeTimestampMilliseconds(_ value: Int64) -> Int64? {
        guard value > 0 else { return nil }
        if value > 10_000_000_000_000 {
            return value / 1_000
        }
        if value > 10_000_000_000 {
            return value
        }
        return value * 1_000
    }

    private func sqliteIntegrity(codexHome: URL) throws -> String {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return "missing" }
        return try withDatabase(path: db.path, readOnly: true) { database in
            try queryRows(database: database, sql: "PRAGMA integrity_check;") { statement in
                sqliteText(statement, 0) ?? "unknown"
            }.first ?? "unknown"
        }
    }

    private func reconcileSessionIndex(codexHome: URL) throws -> Int {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        let rows = try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return [ProviderSyncThreadIndexRow]()
            }
            let titleExpression = columns.title ? "COALESCE(title, '')" : "''"
            let updatedExpression = sqliteUpdatedAtMillisecondsExpression(columns: columns)
            let queriedRows = try queryRows(
                database: database,
                sql: """
                SELECT id, \(titleExpression), \(updatedExpression)
                FROM threads
                ORDER BY \(updatedExpression) ASC, id ASC;
                """
            ) { statement in
                ProviderSyncThreadIndexRow(
                    id: sqliteText(statement, 0) ?? "",
                    title: sqliteText(statement, 1) ?? "",
                    updatedAtMilliseconds: sqliteInt64(statement, 2)
                )
            }
            return queriedRows.filter { !$0.id.isEmpty }
        }

        let index = codexHome.appendingPathComponent("session_index.jsonl")
        let existing = try readSessionIndexLines(codexHome: codexHome)
        var seenIDs = Set<String>()
        var lines: [String] = []

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in existing.lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let id = sessionIndexLineInfo(line)?.id {
                seenIDs.insert(id)
            }
            lines.append(line)
        }

        let missingRows = rows.filter { !seenIDs.contains($0.id) }
        for row in missingRows {
            lines.append(try makeSessionIndexLine(row: row, existingLine: nil, formatter: formatter))
        }
        guard !missingRows.isEmpty else { return 0 }

        var output = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        output.append(0x0A)
        try output.write(to: index, options: [.atomic])
        return missingRows.count
    }

    private func makeSessionIndexLine(
        row: ProviderSyncThreadIndexRow,
        existingLine: String?,
        formatter: ISO8601DateFormatter
    ) throws -> String {
        let date = Date(timeIntervalSince1970: Double(row.updatedAtMilliseconds) / 1000)
        var object: [String: Any] = [:]
        if let existingLine,
           let data = existingLine.data(using: .utf8),
           let existingObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existingObject
        }
        let sqliteTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingTitle = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        object["id"] = row.id
        object["thread_name"] = sqliteTitle.isEmpty ? (existingTitle.isEmpty ? "Untitled" : existingTitle) : row.title
        object["updated_at"] = formatter.string(from: date)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func readSessionIndexIDs(codexHome: URL) throws -> (ids: Set<String>, rows: Int) {
        let result = try readSessionIndexLines(codexHome: codexHome)
        return (result.ids, result.rows)
    }

    private func readSessionIndexLines(codexHome: URL) throws -> ProviderSyncSessionIndexLines {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        guard fileManager.fileExists(atPath: index.path) else {
            return ProviderSyncSessionIndexLines(lines: [], ids: [], rows: 0)
        }
        let text = try String(contentsOf: index, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var ids = Set<String>()
        var rows = 0
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows += 1
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else {
                continue
            }
            ids.insert(id)
        }
        return ProviderSyncSessionIndexLines(lines: lines, ids: ids, rows: rows)
    }

    private func sessionIndexLineInfo(_ line: String) -> (id: String, updatedAtMilliseconds: Int64)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            return nil
        }
        return (id, parseISO8601Milliseconds(object["updated_at"] as? String))
    }

    private func parseISO8601Milliseconds(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    private func readWorkspaceOrderIssues(codexHome: URL) throws -> [ProviderSyncWorkspaceIssue] {
        let globalState = codexHome.appendingPathComponent(".codex-global-state.json")
        guard fileManager.fileExists(atPath: globalState.path),
              let object = try readGlobalStateObject(globalState),
              let projectOrder = object["project-order"] as? [String] else {
            return []
        }

        let threadCounts = try readActiveThreadCountsByCwd(codexHome: codexHome)
        let labels = object["electron-workspace-root-labels"] as? [String: String] ?? [:]
        let candidates = workspaceRootCandidates(from: object)
        let ordered = Set(projectOrder)
        return candidates.compactMap { path in
            let threadCount = threadCounts[path] ?? 0
            guard threadCount > 0, !ordered.contains(path) else { return nil }
            return ProviderSyncWorkspaceIssue(
                path: path,
                label: labels[path] ?? URL(fileURLWithPath: path).lastPathComponent,
                threadCount: threadCount
            )
        }
    }

    private func readVisibilitySummary(codexHome: URL) throws -> ProviderSyncVisibilitySummary {
        let globalState = codexHome.appendingPathComponent(".codex-global-state.json")
        let globalObject = (fileManager.fileExists(atPath: globalState.path) ? try readGlobalStateObject(globalState) : nil) ?? [:]
        let activeWorkspacePath = (globalObject["active-workspace-roots"] as? [String])?.first
        let labels = globalObject["electron-workspace-root-labels"] as? [String: String] ?? [:]

        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else {
            return ProviderSyncVisibilitySummary(activeWorkspacePath: activeWorkspacePath)
        }

        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return ProviderSyncVisibilitySummary(activeWorkspacePath: activeWorkspacePath)
            }

            let archived = columns.archived ? "COALESCE(archived, 0)" : "0"
            let threadSource = columns.threadSource ? "COALESCE(thread_source, 'user')" : "'user'"
            let preview = threadListPreviewExpression(columns: columns)
            let source = columns.source ? "COALESCE(source, '')" : "''"
            let cwd = columns.cwd ? "COALESCE(cwd, '')" : "''"
            let listVisible = "\(archived) = 0 AND \(preview) <> ''"
            let desktopUser = "\(listVisible) AND \(source) = 'vscode'"
            let activeWorkspace = activeWorkspacePath ?? ""
            let activeWorkspacePrefix = activeWorkspace.isEmpty ? "" : "\(activeWorkspace)/%"

            let totals = try queryBoundRows(
                database: database,
                sql: """
                SELECT
                    COUNT(*),
                    SUM(CASE WHEN \(listVisible) THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(archived) <> 0 THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(listVisible) THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(desktopUser) THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(desktopUser) AND (?1 <> '' AND (\(cwd) = ?1 OR \(cwd) LIKE ?2)) THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(listVisible) AND \(source) IN ('cli', 'exec') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN \(archived) = 0 AND \(threadSource) = 'subagent' THEN 1 ELSE 0 END)
                FROM threads;
                """,
                values: [activeWorkspace, activeWorkspacePrefix]
            ) { statement in
                ProviderSyncVisibilitySummary(
                    sqliteThreads: Int(sqliteInt64(statement, 0)),
                    activeThreads: Int(sqliteInt64(statement, 1)),
                    archivedThreads: Int(sqliteInt64(statement, 2)),
                    userThreads: Int(sqliteInt64(statement, 3)),
                    desktopUserThreads: Int(sqliteInt64(statement, 4)),
                    currentWorkspaceDesktopThreads: Int(sqliteInt64(statement, 5)),
                    cliExecUserThreads: Int(sqliteInt64(statement, 6)),
                    subagentThreads: Int(sqliteInt64(statement, 7)),
                    activeWorkspacePath: activeWorkspacePath,
                    workspaces: []
                )
            }.first ?? ProviderSyncVisibilitySummary(activeWorkspacePath: activeWorkspacePath)

            let workspaceRows = try queryRows(
                database: database,
                sql: """
                SELECT
                    \(cwd),
                    SUM(CASE WHEN \(desktopUser) THEN 1 ELSE 0 END),
                    COUNT(*)
                FROM threads
                WHERE \(listVisible)
                  AND \(cwd) <> ''
                GROUP BY \(cwd)
                ORDER BY SUM(CASE WHEN \(desktopUser) THEN 1 ELSE 0 END) DESC, COUNT(*) DESC, \(cwd) ASC
                LIMIT 8;
                """
            ) { statement in
                let path = sqliteText(statement, 0) ?? ""
                let desktopCount = Int(sqliteInt64(statement, 1))
                let interactiveCount = Int(sqliteInt64(statement, 2))
                let label = labels[path] ?? URL(fileURLWithPath: path).lastPathComponent
                let isActive = activeWorkspacePath.map { path == $0 || path.hasPrefix("\($0)/") } ?? false
                return ProviderSyncWorkspaceCount(
                    path: path,
                    label: label,
                    threadCount: desktopCount,
                    interactiveThreadCount: interactiveCount,
                    isActive: isActive
                )
            }

            var summary = totals
            summary.workspaces = workspaceRows
            return summary
        }
    }

    private func reconcileWorkspaceOrder(codexHome: URL) throws -> Int {
        let globalState = codexHome.appendingPathComponent(".codex-global-state.json")
        guard fileManager.fileExists(atPath: globalState.path),
              var object = try readGlobalStateObject(globalState) else {
            return 0
        }

        var projectOrder = object["project-order"] as? [String] ?? []
        let existing = Set(projectOrder)
        let threadCounts = try readActiveThreadCountsByCwd(codexHome: codexHome)
        let missing = workspaceRootCandidates(from: object).filter { path in
            (threadCounts[path] ?? 0) > 0 && !existing.contains(path)
        }
        guard !missing.isEmpty else { return 0 }

        projectOrder.append(contentsOf: missing)
        object["project-order"] = projectOrder
        try writeGlobalStateObject(object, to: globalState)

        let companionBackup = codexHome.appendingPathComponent(".codex-global-state.json.bak")
        if fileManager.fileExists(atPath: companionBackup.path) {
            try writeGlobalStateObject(object, to: companionBackup)
        }
        return missing.count
    }

    private func readGlobalStateObject(_ file: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: file)
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func writeGlobalStateObject(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: [.atomic])
    }

    private func workspaceRootCandidates(from object: [String: Any]) -> [String] {
        var result: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, !result.contains(path) else { return }
            result.append(path)
        }

        (object["electron-saved-workspace-roots"] as? [String] ?? []).forEach(append)
        if let labels = object["electron-workspace-root-labels"] as? [String: String] {
            labels.keys.sorted().forEach(append)
        }
        (object["pinned-project-ids"] as? [String] ?? []).forEach(append)
        return result
    }

    private func readActiveThreadCountsByCwd(codexHome: URL) throws -> [String: Int] {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return [:] }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return [:]
            }
            let archivedPredicate = columns.archived ? "COALESCE(archived, 0) = 0" : "1 = 1"
            let previewPredicate = "\(threadListPreviewExpression(columns: columns)) <> ''"
            let rows = try queryRows(
                database: database,
                sql: """
                SELECT cwd, COUNT(*)
                FROM threads
                WHERE COALESCE(cwd, '') <> ''
                  AND \(archivedPredicate)
                  AND \(previewPredicate)
                GROUP BY cwd;
                """
            ) { statement in
                (sqliteText(statement, 0) ?? "", Int(sqliteInt64(statement, 1)))
            }
            return Dictionary(uniqueKeysWithValues: rows.filter { !$0.0.isEmpty })
        }
    }

    private func readThreadsTableColumns(database: SQLiteDatabaseConnection) throws -> ProviderSyncSQLiteThreadColumns? {
        let names = try queryRows(database: database, sql: "PRAGMA table_info(threads);") { statement in
            sqliteText(statement, 1) ?? ""
        }
        let columns = Set(names.filter { !$0.isEmpty })
        guard !columns.isEmpty, columns.contains("id") else { return nil }
        return ProviderSyncSQLiteThreadColumns(
            modelProvider: columns.contains("model_provider"),
            hasUserEvent: columns.contains("has_user_event"),
            firstUserMessage: columns.contains("first_user_message"),
            threadSource: columns.contains("thread_source"),
            title: columns.contains("title"),
            preview: columns.contains("preview"),
            source: columns.contains("source"),
            cwd: columns.contains("cwd"),
            archived: columns.contains("archived"),
            updatedAt: columns.contains("updated_at"),
            updatedAtMilliseconds: columns.contains("updated_at_ms")
        )
    }

    private func threadsRepairWhereClause(columns: ProviderSyncSQLiteThreadColumns) -> String? {
        var predicates: [String] = []
        if columns.modelProvider {
            predicates.append("COALESCE(model_provider, '') <> ?1")
        }
        return predicates.isEmpty ? nil : predicates.joined(separator: " OR ")
    }

    private func threadsRepairSetClause(columns: ProviderSyncSQLiteThreadColumns) -> String? {
        var assignments: [String] = []
        if columns.modelProvider {
            assignments.append("model_provider = ?1")
        }
        return assignments.isEmpty ? nil : assignments.joined(separator: ", ")
    }

    private func threadListPreviewExpression(columns: ProviderSyncSQLiteThreadColumns) -> String {
        if columns.preview {
            return "COALESCE(preview, '')"
        }
        if columns.firstUserMessage {
            return "COALESCE(first_user_message, '')"
        }
        if columns.title {
            return "COALESCE(title, '')"
        }
        return "''"
    }

    private func sqliteUpdatedAtMillisecondsExpression(columns: ProviderSyncSQLiteThreadColumns) -> String {
        let updatedAtMilliseconds = """
        CASE
            WHEN updated_at > 10000000000000 THEN updated_at / 1000
            WHEN updated_at > 10000000000 THEN updated_at
            ELSE updated_at * 1000
        END
        """
        if columns.updatedAtMilliseconds && columns.updatedAt {
            return "COALESCE(updated_at_ms, \(updatedAtMilliseconds))"
        }
        if columns.updatedAtMilliseconds {
            return "COALESCE(updated_at_ms, CAST(strftime('%s','now') AS INTEGER) * 1000)"
        }
        if columns.updatedAt {
            return updatedAtMilliseconds
        }
        return "CAST(strftime('%s','now') AS INTEGER) * 1000"
    }

    private func createBackup(codexHome: URL, sessionFiles: [URL], targetProvider: String) throws -> URL {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHistoryRepair/backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupName = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let backup = root.appendingPathComponent(backupName, isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        try copyIfExists(codexHome.appendingPathComponent("config.toml"), to: backup.appendingPathComponent("config.toml.before"))
        try backupSQLiteDatabase(
            source: codexHome.appendingPathComponent("state_5.sqlite"),
            destination: backup.appendingPathComponent("state_5.sqlite.before")
        )
        try copyIfExists(codexHome.appendingPathComponent("session_index.jsonl"), to: backup.appendingPathComponent("session_index.jsonl.before"))
        try copyIfExists(codexHome.appendingPathComponent(".codex-global-state.json"), to: backup.appendingPathComponent("codex-global-state.json.before"))
        try copyIfExists(codexHome.appendingPathComponent(".codex-global-state.json.bak"), to: backup.appendingPathComponent("codex-global-state.json.bak.before"))
        try createSessionTar(files: sessionFiles, destination: backup.appendingPathComponent("session-jsonl.before.tar"))

        let manifest: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "codex_home": codexHome.path,
            "target_provider": targetProvider,
            "session_file_count": sessionFiles.count
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: backup.appendingPathComponent("manifest.json"), options: [.atomic])
        return backup
    }

    private func copyIfExists(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func backupSQLiteDatabase(source: URL, destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try withDatabase(path: source.path, readOnly: true) { database in
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            _ = try executeBoundUpdate(
                database: database,
                sql: "VACUUM main INTO ?;",
                values: [destination.path]
            )
        }
    }

    private func createSessionTar(files: [URL], destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-C", "/", "-cf", destination.path] + files.map { String($0.path.dropFirst()) }
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar failed"
            throw NSError(domain: "CodexTokenBar", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func latestBackupDirectory(for codexHome: URL) throws -> URL {
        guard let latest = backupDirectories(for: codexHome).first else {
            throw NSError(domain: "CodexTokenBar", code: 404, userInfo: [NSLocalizedDescriptionKey: "当前 Codex Home 没有可回滚的备份"])
        }
        return latest
    }

    private func backupRecords(for codexHome: URL) -> [ProviderSyncBackupRecord] {
        let sortedOldestFirst = backupDirectories(for: codexHome).reversed()
        return sortedOldestFirst.enumerated().map { index, backup in
            let metadata = backupMetadata(backup)
            return ProviderSyncBackupRecord(
                path: backup.path,
                name: backup.lastPathComponent,
                createdAt: metadata.createdAt ?? modificationDate(of: backup) ?? .distantPast,
                sequence: index + 1,
                targetProvider: metadata.targetProvider ?? "未知 provider",
                sessionFileCount: metadata.sessionFileCount ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.sequence > rhs.sequence
        }
    }

    private func backupDirectories(for codexHome: URL) -> [URL] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHistoryRepair/backups", isDirectory: true)
        let backups = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return backups
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { backupMatchesCodexHome($0, codexHome: codexHome) }
            .sorted { lhs, rhs in
                let lhsDate = backupMetadata(lhs).createdAt ?? modificationDate(of: lhs) ?? .distantPast
                let rhsDate = backupMetadata(rhs).createdAt ?? modificationDate(of: rhs) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func backupMetadata(_ backup: URL) -> (createdAt: Date?, targetProvider: String?, sessionFileCount: Int?) {
        let manifest = backup.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let createdAt = (object["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let targetProvider = object["target_provider"] as? String
        let sessionFileCount = object["session_file_count"] as? Int
        return (createdAt, targetProvider, sessionFileCount)
    }

    private func backupMatchesCodexHome(_ backup: URL, codexHome: URL) -> Bool {
        let manifest = backup.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backedUpHome = object["codex_home"] as? String else {
            return false
        }
        return URL(fileURLWithPath: backedUpHome).standardizedFileURL.path == codexHome.standardizedFileURL.path
    }

    private func restoreBackup(_ backup: URL, codexHome: URL) throws {
        guard backupMatchesCodexHome(backup, codexHome: codexHome) else {
            throw NSError(domain: "CodexTokenBar", code: 400, userInfo: [NSLocalizedDescriptionKey: "备份不属于当前 Codex Home，已拒绝回滚"])
        }

        try restoreFileIfBackedUp(backup.appendingPathComponent("config.toml.before"), to: codexHome.appendingPathComponent("config.toml"), removeIfMissing: false)
        let state = codexHome.appendingPathComponent("state_5.sqlite")
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("state_5.sqlite.before"), to: state, removeIfMissing: false)
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("session_index.jsonl.before"), to: codexHome.appendingPathComponent("session_index.jsonl"), removeIfMissing: true)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.before"), to: codexHome.appendingPathComponent(".codex-global-state.json"), removeIfMissing: false)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.bak.before"), to: codexHome.appendingPathComponent(".codex-global-state.json.bak"), removeIfMissing: false)

        let tar = backup.appendingPathComponent("session-jsonl.before.tar")
        if fileManager.fileExists(atPath: tar.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-C", "/", "-xf", tar.path]
            let error = Pipe()
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar restore failed"
                throw NSError(domain: "CodexTokenBar", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private func restoreFileIfBackedUp(_ source: URL, to destination: URL, removeIfMissing: Bool) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            if removeIfMissing, fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    private func removeSQLiteSidecars(for database: URL) throws {
        for suffix in ["-shm", "-wal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
    }

    private func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    private func restoreModificationDate(_ date: Date?, for file: URL) {
        guard let date else { return }
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let name = app.localizedName else { return false }
            return name == "Codex"
        }
    }

    private func withDatabase<T>(path: String, readOnly: Bool, body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: path),
            readOnly: readOnly,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.withConnection(body)
    }

    private func queryRows<T>(database: SQLiteDatabaseConnection, sql: String, map: (SQLiteStatement) throws -> T) throws -> [T] {
        try database.readRows(sql, map: map)
    }

    private func queryBoundRows<T>(database: SQLiteDatabaseConnection, sql: String, values: [String], map: (SQLiteStatement) throws -> T) throws -> [T] {
        try database.readRows(sql, bindings: values.map(SQLiteBinding.text), map: map)
    }

    private func execute(database: SQLiteDatabaseConnection, sql: String) throws {
        try database.execute(sql)
    }

    private func executeBoundUpdate(database: SQLiteDatabaseConnection, sql: String, values: [String]) throws -> Int {
        try database.executeChangedRows(sql, bindings: values.map(SQLiteBinding.text))
    }

    private func executeTimestampUpdate(
        database: SQLiteDatabaseConnection,
        columns: ProviderSyncSQLiteThreadColumns,
        timestamp: ProviderSyncSessionTimestamp
    ) throws -> Int {
        let seconds = timestamp.updatedAtMilliseconds / 1_000
        let sql: String
        if columns.updatedAt && columns.updatedAtMilliseconds {
            sql = """
            UPDATE threads
            SET updated_at = ?2, updated_at_ms = ?3
            WHERE id = ?1
              AND (updated_at <> ?2 OR COALESCE(updated_at_ms, 0) <> ?3);
            """
        } else if columns.updatedAt {
            sql = """
            UPDATE threads
            SET updated_at = ?2
            WHERE id = ?1
              AND updated_at <> ?2;
            """
        } else {
            sql = """
            UPDATE threads
            SET updated_at_ms = ?3
            WHERE id = ?1
              AND COALESCE(updated_at_ms, 0) <> ?3;
            """
        }

        return try database.executeChangedRows(sql, bindings: [
            .text(timestamp.id),
            .int64(seconds),
            .int64(timestamp.updatedAtMilliseconds)
        ])
    }

    private func sqliteText(_ statement: SQLiteStatement, _ column: Int32) -> String? {
        statement.text(column)
    }

    private func sqliteInt64(_ statement: SQLiteStatement, _ column: Int32) -> Int64 {
        statement.int64(column) ?? 0
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
