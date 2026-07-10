import AppKit
import Foundation

struct ProviderSyncReport {
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

struct ProviderSyncSQLiteProvider {
    var provider: String
    var archived: Int
    var count: Int
}

struct ProviderSyncThreadIndexRow {
    var id: String
    var title: String
    var updatedAtMilliseconds: Int64
}

struct ProviderSyncSessionTimestamp {
    var id: String
    var updatedAtMilliseconds: Int64
    var fileURL: URL
}

struct ProviderSyncThreadTimestampRow {
    var id: String
    var updatedAtMilliseconds: Int64
}

struct ProviderSyncSessionIndexLines {
    var lines: [String]
    var ids: Set<String>
    var rows: Int
}

struct ProviderSyncSQLiteThreadColumns {
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

enum CodexDesktopApplicationMatcher {
    static func matches(bundleIdentifier: String?, localizedName: String?) -> Bool {
        if bundleIdentifier == CodexApplicationLocator.bundleIdentifier {
            return true
        }
        return localizedName == "Codex" || localizedName == "ChatGPT"
    }
}

final class ProviderSyncEngine {
    let fileManager: FileManager
    private let backupRootOverride: URL?

    init(fileManager: FileManager = .default, backupRoot: URL? = nil) {
        self.fileManager = fileManager
        self.backupRootOverride = backupRoot
    }

    func backupRootDirectory() -> URL {
        backupRootOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHistoryRepair/backups", isDirectory: true)
    }

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

    func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    func restoreModificationDate(_ date: Date?, for file: URL) {
        guard let date else { return }
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            CodexDesktopApplicationMatcher.matches(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        }
    }

    func withDatabase<T>(path: String, readOnly: Bool, body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: path),
            readOnly: readOnly,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.withConnection(body)
    }

    func queryRows<T>(database: SQLiteDatabaseConnection, sql: String, map: (SQLiteStatement) throws -> T) throws -> [T] {
        try database.readRows(sql, map: map)
    }

    func queryBoundRows<T>(database: SQLiteDatabaseConnection, sql: String, values: [String], map: (SQLiteStatement) throws -> T) throws -> [T] {
        try database.readRows(sql, bindings: values.map(SQLiteBinding.text), map: map)
    }

    func execute(database: SQLiteDatabaseConnection, sql: String) throws {
        try database.execute(sql)
    }

    func executeBoundUpdate(database: SQLiteDatabaseConnection, sql: String, values: [String]) throws -> Int {
        try database.executeChangedRows(sql, bindings: values.map(SQLiteBinding.text))
    }

    func executeTimestampUpdate(
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

    func sqliteText(_ statement: SQLiteStatement, _ column: Int32) -> String? {
        statement.text(column)
    }

    func sqliteInt64(_ statement: SQLiteStatement, _ column: Int32) -> Int64 {
        statement.int64(column) ?? 0
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
