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
        if let bundleIdentifier {
            return bundleIdentifier == CodexApplicationLocator.bundleIdentifier
        }
        return localizedName == "Codex" || localizedName == "ChatGPT"
    }
}

enum ProviderSyncMutationError: LocalizedError, Equatable, Sendable {
    case codexRunning(operation: String)

    var errorDescription: String? {
        switch self {
        case .codexRunning(let operation):
            return "\(operation) 已拒绝：Codex 正在运行。请先退出 Codex Desktop，再重新执行 Provider 修复。"
        }
    }
}

final class ProviderSyncEngine {
    private static let mutationLeaseRegistry = ProviderSyncMutationLeaseRegistry()

    let fileManager: FileManager
    private let backupRootOverride: URL?
    private let applicationRunningProbe: @Sendable () -> Bool
    private let mutationLeaseDidAcquire: (@Sendable () -> Void)?
    private let reportWillBuild: (() throws -> Void)?
    let restoreWillApply: ((Int, URL) throws -> Void)?
    let restoreDestinationWillJournal: ((Int, URL) throws -> Void)?
    let restoreWillVerifyApplied: ((Int, URL) throws -> Void)?
    let restoreWillCompensate: ((Int, URL) throws -> Void)?
    let restoreWillVerifyCompensated: ((Int, URL) throws -> Void)?
    let restoreJournalWillOpen: ((Int, URL) throws -> Void)?
    let restoreJournalDidRead: ((Int, URL) throws -> Void)?
    let restoreCleanupWillBegin: ((URL) throws -> Void)?
    let restoreCleanupDidRemoveEntry: ((URL) throws -> Void)?
    let restoreCleanupWillRemoveRoot: ((URL) throws -> Void)?
    let sessionArchiveDidList: (() throws -> Void)?
    let regularFileWillOpen: ((URL) throws -> Void)?
    let backupWillReadHome: (() throws -> Void)?
    let sessionTarWillRun: (() throws -> Void)?
    let sessionTarStageWillRun: ((URL) throws -> Void)?
    let sessionTarDidRun: ((URL) throws -> Void)?
    let sessionMutationsWillBegin: (() throws -> Void)?
    let sessionMutationsDidApply: (() throws -> Void)?
    let sessionReplacementWillExchange: ((URL) throws -> Void)?
    let sqliteTimestampWillOpen: (() throws -> Void)?
    let sqliteProviderWillOpen: (() throws -> Void)?
    let sessionIndexWillReplace: ((URL) throws -> Void)?
    let globalStateWillReplace: ((URL) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        backupRoot: URL? = nil,
        applicationRunningProbe: @escaping @Sendable () -> Bool = ProviderSyncEngine.defaultApplicationRunningProbe,
        mutationLeaseDidAcquire: (@Sendable () -> Void)? = nil,
        reportWillBuild: (() throws -> Void)? = nil,
        restoreWillApply: ((Int, URL) throws -> Void)? = nil,
        restoreDestinationWillJournal: ((Int, URL) throws -> Void)? = nil,
        restoreWillVerifyApplied: ((Int, URL) throws -> Void)? = nil,
        restoreWillCompensate: ((Int, URL) throws -> Void)? = nil,
        restoreWillVerifyCompensated: ((Int, URL) throws -> Void)? = nil,
        restoreJournalWillOpen: ((Int, URL) throws -> Void)? = nil,
        restoreJournalDidRead: ((Int, URL) throws -> Void)? = nil,
        restoreCleanupWillBegin: ((URL) throws -> Void)? = nil,
        restoreCleanupDidRemoveEntry: ((URL) throws -> Void)? = nil,
        restoreCleanupWillRemoveRoot: ((URL) throws -> Void)? = nil,
        sessionArchiveDidList: (() throws -> Void)? = nil,
        regularFileWillOpen: ((URL) throws -> Void)? = nil,
        backupWillReadHome: (() throws -> Void)? = nil,
        sessionTarWillRun: (() throws -> Void)? = nil,
        sessionTarStageWillRun: ((URL) throws -> Void)? = nil,
        sessionTarDidRun: ((URL) throws -> Void)? = nil,
        sessionMutationsWillBegin: (() throws -> Void)? = nil,
        sessionMutationsDidApply: (() throws -> Void)? = nil,
        sessionReplacementWillExchange: ((URL) throws -> Void)? = nil,
        sqliteTimestampWillOpen: (() throws -> Void)? = nil,
        sqliteProviderWillOpen: (() throws -> Void)? = nil,
        sessionIndexWillReplace: ((URL) throws -> Void)? = nil,
        globalStateWillReplace: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.backupRootOverride = backupRoot
        self.applicationRunningProbe = applicationRunningProbe
        self.mutationLeaseDidAcquire = mutationLeaseDidAcquire
        self.reportWillBuild = reportWillBuild
        self.restoreWillApply = restoreWillApply
        self.restoreDestinationWillJournal = restoreDestinationWillJournal
        self.restoreWillVerifyApplied = restoreWillVerifyApplied
        self.restoreWillCompensate = restoreWillCompensate
        self.restoreWillVerifyCompensated = restoreWillVerifyCompensated
        self.restoreJournalWillOpen = restoreJournalWillOpen
        self.restoreJournalDidRead = restoreJournalDidRead
        self.restoreCleanupWillBegin = restoreCleanupWillBegin
        self.restoreCleanupDidRemoveEntry = restoreCleanupDidRemoveEntry
        self.restoreCleanupWillRemoveRoot = restoreCleanupWillRemoveRoot
        self.sessionArchiveDidList = sessionArchiveDidList
        self.regularFileWillOpen = regularFileWillOpen
        self.backupWillReadHome = backupWillReadHome
        self.sessionTarWillRun = sessionTarWillRun
        self.sessionTarStageWillRun = sessionTarStageWillRun
        self.sessionTarDidRun = sessionTarDidRun
        self.sessionMutationsWillBegin = sessionMutationsWillBegin
        self.sessionMutationsDidApply = sessionMutationsDidApply
        self.sessionReplacementWillExchange = sessionReplacementWillExchange
        self.sqliteTimestampWillOpen = sqliteTimestampWillOpen
        self.sqliteProviderWillOpen = sqliteProviderWillOpen
        self.sessionIndexWillReplace = sessionIndexWillReplace
        self.globalStateWillReplace = globalStateWillReplace
    }

    func backupRootDirectory() -> URL {
        backupRootOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHistoryRepair/backups", isDirectory: true)
    }

    func scan(codexHome: URL, includeArchivedSessions: Bool) throws -> ProviderSyncSnapshot {
        try withPinnedHome(codexHome: codexHome) { canonicalHome, homeDirectory in
            let report = try makeReport(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: nil
            )
            return snapshot(from: report, status: "扫描完成")
        }
    }

    func verify(codexHome: URL, includeArchivedSessions: Bool, targetProviderOverride: String?) throws -> ProviderSyncSnapshot {
        try withPinnedHome(codexHome: codexHome) { canonicalHome, homeDirectory in
            let report = try makeReport(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProviderOverride
            )
            let status = verificationIssues(in: report).isEmpty
                ? "验证通过"
                : "验证完成：仍有历史或前端工作区状态未同步"
            return snapshot(from: report, status: status)
        }
    }

    func sync(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?,
        dryRunOnly: Bool
    ) throws -> ProviderSyncSnapshot {
        return try withMutationLease(codexHome: codexHome) { canonicalHome, homeDirectory in
            let initial = try makeReport(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProviderOverride
            )
            if !dryRunOnly {
                try rejectMutationIfCodexIsRunning(operation: "同步")
            }

            let createdBackup = try createBackupForMutation(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                sessionFiles: initial.sessionFiles,
                targetProvider: initial.targetProvider
            )
            let backupPath = createdBackup.url

            var changedSessionFiles = 0
            var sqliteRowsChanged = 0
            if dryRunOnly {
                let report = try makeReport(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    includeArchivedSessions: includeArchivedSessions,
                    targetProviderOverride: targetProviderOverride
                )
                var next = snapshot(from: report, status: "Dry run 完成，已创建备份但未改历史")
                next.lastBackupPath = backupPath.path
                return next
            }

            try sessionMutationsWillBegin?()
            try homeDirectory.verifyRootPathIdentity()
            let preparedSessionMutations = try prepareSessionMutations(
                homeDirectory: homeDirectory,
                bindings: createdBackup.sessionBindings,
                targetProvider: initial.targetProvider
            )

            do {
                for mutation in preparedSessionMutations {
                    if try applyPreparedSessionMutation(
                        mutation,
                        homeDirectory: homeDirectory
                    ) {
                        changedSessionFiles += 1
                    }
                }
            } catch let sessionError {
                do {
                    try rollbackPreparedSessionMutations(
                        preparedSessionMutations,
                        homeDirectory: homeDirectory
                    )
                } catch let rollbackError {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 500,
                        userInfo: [
                            NSLocalizedDescriptionKey: "session mutation 失败且 descriptor rollback 不完整：\(sessionError.localizedDescription)；\(rollbackError.localizedDescription)"
                        ]
                    )
                }
                throw sessionError
            }

            do {
                try commitPreparedSessionMutations(
                    preparedSessionMutations,
                    homeDirectory: homeDirectory
                )
                try sessionMutationsDidApply?()
                sqliteRowsChanged = try repairSQLiteThreadTimestamps(
                    sessionMutations: preparedSessionMutations,
                    homeDirectory: homeDirectory
                )
                sqliteRowsChanged += try updateSQLite(
                    homeDirectory: homeDirectory,
                    targetProvider: initial.targetProvider
                )
                _ = try reconcileSessionIndex(homeDirectory: homeDirectory)
                _ = try reconcileWorkspaceOrder(homeDirectory: homeDirectory)
                try validatePreparedSessionMutations(
                    preparedSessionMutations,
                    homeDirectory: homeDirectory
                )

                let verified = try makeReport(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    includeArchivedSessions: includeArchivedSessions,
                    targetProviderOverride: targetProviderOverride
                )
                let issues = verificationIssues(
                    in: verified,
                    expectedSessionFileCount: initial.sessionFiles.count,
                    expectedSQLiteRowCount: initial.sqliteProviders.reduce(0) { $0 + $1.count }
                )
                guard issues.isEmpty else {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 422,
                        userInfo: [
                            NSLocalizedDescriptionKey: "写后验证失败：\(issues.joined(separator: "；"))"
                        ]
                    )
                }
                try validatePreparedSessionMutations(
                    preparedSessionMutations,
                    homeDirectory: homeDirectory
                )

                var next = snapshot(from: verified, status: "同步完成并已验证")
                next.changedSessionFiles = changedSessionFiles
                next.sqliteRowsChanged = sqliteRowsChanged
                next.lastBackupPath = backupPath.path
                return next
            } catch let operationError {
                do {
                    _ = try restoreBackup(
                        backupPath,
                        codexHome: canonicalHome,
                        homeDirectory: homeDirectory
                    ) {
                        try makeReport(
                            codexHome: canonicalHome,
                            homeDirectory: homeDirectory,
                            includeArchivedSessions: includeArchivedSessions,
                            targetProviderOverride: nil
                        )
                    }
                } catch let rollbackError {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 500,
                        userInfo: [
                            NSLocalizedDescriptionKey: "同步失败，且自动回滚失败：\(operationError.localizedDescription)；回滚错误：\(rollbackError.localizedDescription)"
                        ]
                    )
                }
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [
                        NSLocalizedDescriptionKey: "同步失败，已自动回滚：\(operationError.localizedDescription)"
                    ]
                )
            }
        }
    }

    func rollbackLatest(codexHome: URL) throws -> ProviderSyncSnapshot {
        try withMutationLease(codexHome: codexHome) { canonicalHome, homeDirectory in
            try rejectMutationIfCodexIsRunning(operation: "回滚")
            let backup = try latestBackupDirectory(for: canonicalHome)
            return try rollbackWithoutLease(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                backup: backup,
                status: "已从最近备份回滚"
            )
        }
    }

    func rollback(codexHome: URL, backupPath: String) throws -> ProviderSyncSnapshot {
        try withMutationLease(codexHome: codexHome) { canonicalHome, homeDirectory in
            try rejectMutationIfCodexIsRunning(operation: "回滚")
            return try rollbackWithoutLease(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory,
                backup: URL(fileURLWithPath: backupPath),
                status: "已从所选备份回滚"
            )
        }
    }

    private func rollbackWithoutLease(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        backup: URL,
        status: String
    ) throws -> ProviderSyncSnapshot {
        try restoreBackup(backup, codexHome: codexHome, homeDirectory: homeDirectory) {
            let report = try makeReport(
                codexHome: codexHome,
                homeDirectory: homeDirectory,
                includeArchivedSessions: true,
                targetProviderOverride: nil
            )
            var next = snapshot(from: report, status: status)
            next.lastBackupPath = backup.path
            return next
        }
    }

    private func makeReport(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?
    ) throws -> ProviderSyncReport {
        try reportWillBuild?()
        try homeDirectory.verifyRootPathIdentity()
        let sessionFiles = findSessionFiles(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions)
        try homeDirectory.verifyRootPathIdentity()
        var sessionProviders: [String: Int] = [:]
        var invalidSessionFiles = 0
        for file in sessionFiles {
            guard let provider = try readSessionProvider(
                file: file,
                homeDirectory: homeDirectory
            ) else {
                invalidSessionFiles += 1
                continue
            }
            sessionProviders[provider, default: 0] += 1
        }

        let sqliteProviders = try readSQLiteProviders(homeDirectory: homeDirectory)
        let latestSQLite = try latestSQLiteProvider(homeDirectory: homeDirectory)
        let configProvider = try configProvider(homeDirectory: homeDirectory)
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

        let indexIDs = try readSessionIndexIDs(homeDirectory: homeDirectory)
        let sqliteRowsToRepair = try countSQLiteRowsToRepair(
            homeDirectory: homeDirectory,
            targetProvider: targetProvider
        )
        let workspaceIssues = try readWorkspaceOrderIssues(homeDirectory: homeDirectory)
        let visibilitySummary = try readVisibilitySummary(homeDirectory: homeDirectory)
        let integrity = try sqliteIntegrity(homeDirectory: homeDirectory)
        try homeDirectory.verifyRootPathIdentity()
        return ProviderSyncReport(
            codexHome: codexHome,
            targetProvider: targetProvider,
            providerSource: providerSource,
            sessionFiles: sessionFiles,
            sessionProviders: sessionProviders,
            invalidSessionFiles: invalidSessionFiles,
            sqliteProviders: sqliteProviders,
            sqliteRowsToRepair: sqliteRowsToRepair,
            sqliteIntegrity: integrity,
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

    private func verificationIssues(
        in report: ProviderSyncReport,
        expectedSessionFileCount: Int? = nil,
        expectedSQLiteRowCount: Int? = nil
    ) -> [String] {
        var issues: [String] = []
        let checkedSessionCount = report.sessionProviders.values.reduce(0, +)
        let checkedSQLiteRowCount = report.sqliteProviders.reduce(0) { $0 + $1.count }

        if report.invalidSessionFiles > 0 {
            issues.append("发现 \(report.invalidSessionFiles) 个无效会话文件")
        }
        if checkedSessionCount != report.sessionFiles.count {
            issues.append("会话 Provider 校验不完整")
        }
        if let expectedSessionFileCount {
            if expectedSessionFileCount > 0, checkedSessionCount == 0 {
                issues.append("会话校验为空")
            }
            if report.sessionFiles.count != expectedSessionFileCount {
                issues.append("会话文件数量从 \(expectedSessionFileCount) 变为 \(report.sessionFiles.count)")
            }
        }
        if !report.sessionProviders.keys.allSatisfy({ $0 == report.targetProvider }) {
            issues.append("会话 Provider 未全部同步为 \(report.targetProvider)")
        }
        if let expectedSQLiteRowCount {
            if expectedSQLiteRowCount > 0, checkedSQLiteRowCount == 0 {
                issues.append("SQLite Provider 校验为空")
            }
            if checkedSQLiteRowCount != expectedSQLiteRowCount {
                issues.append("SQLite 行数从 \(expectedSQLiteRowCount) 变为 \(checkedSQLiteRowCount)")
            }
        }
        if !report.sqliteProviders.allSatisfy({ $0.provider == report.targetProvider }) {
            issues.append("SQLite Provider 未全部同步为 \(report.targetProvider)")
        }
        if report.sqliteRowsToRepair != 0 {
            issues.append("仍有 \(report.sqliteRowsToRepair) 行 SQLite 数据待修复")
        }
        if report.sqliteIntegrity != "ok" {
            issues.append("SQLite 完整性检查失败：\(report.sqliteIntegrity)")
        }
        if !report.workspaceIssues.isEmpty {
            issues.append("仍有 \(report.workspaceIssues.count) 个工作区问题")
        }
        return issues
    }

    func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    func isCodexRunning() -> Bool {
        applicationRunningProbe()
    }

    private static func defaultApplicationRunningProbe() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            CodexDesktopApplicationMatcher.matches(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        }
    }

    private func rejectMutationIfCodexIsRunning(operation: String) throws {
        guard !isCodexRunning() else {
            throw ProviderSyncMutationError.codexRunning(operation: operation)
        }
    }

    private func withPinnedHome<T>(
        codexHome: URL,
        body: (URL, ProviderSyncHomeDirectory) throws -> T
    ) throws -> T {
        let canonicalHome = canonicalProviderHome(codexHome)
        let homeDirectory = try ProviderSyncHomeDirectory(canonicalURL: canonicalHome)
        defer { try? homeDirectory.close() }
        return try body(canonicalHome, homeDirectory)
    }

    private func withMutationLease<T>(
        codexHome: URL,
        body: (URL, ProviderSyncHomeDirectory) throws -> T
    ) throws -> T {
        let canonicalHome = canonicalProviderHome(codexHome)
        guard Self.mutationLeaseRegistry.acquire(canonicalHome.path) else {
            throw NSError(
                domain: "CodexTokenBar",
                code: 409,
                userInfo: [
                    NSLocalizedDescriptionKey: "已有 Provider 修复操作进行中，请等待完成后再重试"
                ]
            )
        }
        defer {
            Self.mutationLeaseRegistry.release(canonicalHome.path)
        }
        mutationLeaseDidAcquire?()
        let homeDirectory = try ProviderSyncHomeDirectory(canonicalURL: canonicalHome)
        defer { try? homeDirectory.close() }
        return try body(canonicalHome, homeDirectory)
    }

    func canonicalProviderHome(_ codexHome: URL) -> URL {
        codexHome.standardizedFileURL.resolvingSymlinksInPath()
    }

    func withBoundDatabase<T>(
        homeDirectory: ProviderSyncHomeDirectory,
        readOnly: Bool,
        willOpen: (() throws -> Void)? = nil,
        body: (SQLiteDatabaseConnection, ProviderSyncBoundRegularFile) throws -> T
    ) throws -> T? {
        guard let bound = try homeDirectory.bindRegularFile(
            relativePath: "state_5.sqlite",
            requireSingleLink: false
        ) else {
            return nil
        }
        defer { try? bound.close() }
        try willOpen?()
        try homeDirectory.verifyBoundFile(bound)
        let driver = SQLiteDatabaseDriver(
            url: bound.file.displayURL,
            readOnly: readOnly,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.withConnection { database in
            try homeDirectory.verifyBoundFile(bound)
            let result = try body(database, bound)
            try homeDirectory.verifyBoundFile(bound)
            return result
        }
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

private final class ProviderSyncMutationLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeHomes = Set<String>()

    func acquire(_ home: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !activeHomes.contains(home) else {
            return false
        }
        activeHomes.insert(home)
        return true
    }

    func release(_ home: String) {
        lock.lock()
        activeHomes.remove(home)
        lock.unlock()
    }
}
