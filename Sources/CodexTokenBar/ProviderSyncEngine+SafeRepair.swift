import Darwin
import Foundation

struct ProviderSyncMetadataBackup {
    let url: URL
    let sqliteSnapshot: URL
    let checksum: String
}

extension ProviderSyncEngine {
    func repairProviderMetadata(
        codexHome: URL,
        expectedHomeIdentity: CodexHomeIdentity?,
        includeArchivedSessions: Bool
    ) throws -> ProviderSyncSnapshot {
        try withMutationLease(
            codexHome: codexHome,
            expectedHomeIdentity: expectedHomeIdentity
        ) { canonicalHome, homeDirectory in
            try rejectMutationIfCodexIsRunning(operation: "安全修复")
            return try withProviderSQLiteHome(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory
            ) { sqliteHome, sqliteDirectory in
                try reconcileInterruptedProviderMigration(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory
                )
                let initial = try makeReport(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    includeArchivedSessions: includeArchivedSessions,
                    targetProviderOverride: nil
                )
                let backup = try createProviderMetadataBackup(
                    codexHome: canonicalHome,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    targetProvider: initial.targetProvider
                )

                do {
                    let changed = try repairSQLiteProvidersFromSessions(
                        homeDirectory: sqliteDirectory,
                        sessionProviders: initial.canonicalSessionProviders
                    )
                    let verified = try makeReport(
                        codexHome: canonicalHome,
                        homeDirectory: homeDirectory,
                        sqliteHome: sqliteHome,
                        sqliteDirectory: sqliteDirectory,
                        includeArchivedSessions: includeArchivedSessions,
                        targetProviderOverride: nil
                    )
                    guard verified.canonicalSessionProviders
                            == initial.canonicalSessionProviders,
                          verified.sessionFiles.count == initial.sessionFiles.count,
                          verified.sqliteRowsToRepair == 0,
                          verified.sqliteIntegrity == "ok" else {
                        throw providerSyncDescriptorError(
                            "安全修复写后验证失败，Provider 元数据或会话集合发生变化"
                        )
                    }
                    try rejectMutationIfCodexIsRunning(operation: "安全修复提交")
                    var next = snapshot(
                        from: verified,
                        status: "安全修复完成：仅按各会话首行对齐 SQLite Provider"
                    )
                    next.changedSessionFiles = 0
                    next.sqliteRowsChanged = changed
                    next.lastBackupPath = backup.url.path
                    return next
                } catch {
                    do {
                        try restoreProviderMetadataColumns(
                            backup, sqliteDirectory: sqliteDirectory,
                            expectedProviders: initial.canonicalSessionProviders
                        )
                    } catch let rollbackError {
                        throw providerSyncDescriptorError(
                            "安全修复失败且自动回滚失败：\(error.localizedDescription)；\(rollbackError.localizedDescription)"
                        )
                    }
                    throw providerSyncDescriptorError(
                        "安全修复失败，已自动回滚：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func createProviderMetadataBackup(
        codexHome: URL,
        expectedHomeIdentity: CodexHomeIdentity?,
        includeArchivedSessions: Bool
    ) throws -> ProviderSyncSnapshot {
        try withMutationLease(
            codexHome: codexHome,
            expectedHomeIdentity: expectedHomeIdentity
        ) { canonicalHome, homeDirectory in
            try withProviderSQLiteHome(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory
            ) { sqliteHome, sqliteDirectory in
                try reconcileInterruptedProviderMigration(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory
                )
                let report = try makeReport(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    includeArchivedSessions: includeArchivedSessions,
                    targetProviderOverride: nil
                )
                let backup = try createProviderMetadataBackup(
                    codexHome: canonicalHome,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    targetProvider: report.targetProvider
                )
                var next = snapshot(
                    from: report,
                    status: "已创建 SQLite 一致性恢复点；未复制会话正文"
                )
                next.lastBackupPath = backup.url.path
                return next
            }
        }
    }

    func rollbackProviderMetadataBackup(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        backupURL: URL,
        status: String
    ) throws -> ProviderSyncSnapshot? {
        guard providerMetadataBackupKind(at: backupURL) else {
            return nil
        }
        return try withProviderSQLiteHome(
            codexHome: codexHome,
            homeDirectory: homeDirectory
        ) { sqliteHome, sqliteDirectory in
            try reconcileInterruptedProviderMigration(
                codexHome: codexHome,
                homeDirectory: homeDirectory,
                sqliteHome: sqliteHome,
                sqliteDirectory: sqliteDirectory
            )
            let selected = try validatedProviderMetadataBackup(
                at: backupURL,
                codexHome: codexHome,
                sqliteHome: sqliteHome
            )
            let preRollback = try createProviderMetadataBackup(
                codexHome: codexHome,
                sqliteHome: sqliteHome,
                sqliteDirectory: sqliteDirectory,
                targetProvider: "pre-rollback"
            )
            do {
                try restoreProviderMetadataBackup(
                    selected,
                    sqliteDirectory: sqliteDirectory
                )
                let report = try makeReport(
                    codexHome: codexHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    includeArchivedSessions: true,
                    targetProviderOverride: nil
                )
                guard report.sqliteIntegrity == "ok" else {
                    throw providerSyncDescriptorError(
                        "回滚后的 SQLite 完整性检查失败：\(report.sqliteIntegrity)"
                    )
                }
                var next = snapshot(from: report, status: status)
                next.lastBackupPath = backupURL.path
                return next
            } catch {
                throw providerSyncDescriptorError(
                    "Provider 显式恢复未完成：\(error.localizedDescription)；为保留期间的其他写入，未自动覆盖整库。回滚前恢复点：\(preRollback.url.path)"
                )
            }
        }
    }

    private func createProviderMetadataBackup(
        codexHome: URL,
        sqliteHome: URL,
        sqliteDirectory: ProviderSyncHomeDirectory,
        targetProvider: String
    ) throws -> ProviderSyncMetadataBackup {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let root = backupRoot.url
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let identifier = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let staging = root.appendingPathComponent(
            ".provider-metadata-\(identifier)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: staging.path
        )
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: staging)
            }
        }

        try sqliteDirectory.verifyRootPathIdentity()
        let snapshot = staging.appendingPathComponent("state_5.sqlite.before")
        try backupSQLiteDatabase(
            homeDirectory: sqliteDirectory,
            destination: snapshot
        )
        guard fileManager.fileExists(atPath: snapshot.path) else {
            throw providerSyncDescriptorError(
                "当前 SQLite Home 缺少 state_5.sqlite，无法创建恢复点"
            )
        }
        let checksum = try providerSyncSHA256Hex(fileAt: snapshot)
        let manifest: [String: Any] = [
            "schema_version": 2,
            "backup_kind": "provider_metadata",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "codex_home": codexHome.path,
            "canonical_codex_home": codexHome.path,
            "sqlite_home": sqliteHome.path,
            "target_provider": targetProvider,
            "session_file_count": 0,
            "session_members": [],
            "sqlite_sha256": checksum
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try manifestData.write(
            to: manifestURL,
            options: [.atomic]
        )
        try providerSyncFsyncRegularFile(at: snapshot)
        try providerSyncFsyncRegularFile(at: manifestURL)
        try providerSyncFsyncDirectory(at: staging)
        try sqliteDirectory.verifyRootPathIdentity()
        try backupRoot.directory.verifyRootPathIdentity()
        try publishProviderBackup(
            staging: staging,
            destination: destination,
            backupRoot: backupRoot.directory
        )
        published = true
        return ProviderSyncMetadataBackup(
            url: destination,
            sqliteSnapshot: destination.appendingPathComponent(
                "state_5.sqlite.before"
            ),
            checksum: checksum
        )
    }

    private func providerMetadataBackupKind(at backupURL: URL) -> Bool {
        let manifest = backupURL.appendingPathComponent("manifest.json")
        guard let data = try? providerSyncReadSmallRegularFile(
            at: manifest,
            maximumBytes: 1024 * 1024
        ),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return false
        }
        return object["schema_version"] as? Int == 2
            && object["backup_kind"] as? String == "provider_metadata"
    }

    private func validatedProviderMetadataBackup(
        at backupURL: URL,
        codexHome: URL,
        sqliteHome: URL
    ) throws -> ProviderSyncMetadataBackup {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let canonicalRoot = backupRoot.url
        let canonicalBackup = try validatedProviderBackupDirectory(
            backupURL,
            canonicalRoot: canonicalRoot
        )
        let manifestURL = canonicalBackup.appendingPathComponent("manifest.json")
        let data = try providerSyncReadSmallRegularFile(
            at: manifestURL,
            maximumBytes: 1024 * 1024
        )
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["schema_version"] as? Int == 2,
              object["backup_kind"] as? String == "provider_metadata",
              object["canonical_codex_home"] as? String == codexHome.path,
              object["sqlite_home"] as? String == sqliteHome.path,
              let checksum = object["sqlite_sha256"] as? String else {
            throw providerSyncDescriptorError(
                "Provider 恢复点 manifest 与当前 Codex/SQLite Home 不匹配"
            )
        }
        let snapshot = canonicalBackup.appendingPathComponent(
            "state_5.sqlite.before"
        )
        try rejectMutationIfCodexIsRunning(operation: "恢复 Provider 元数据")
        let actualChecksum = try providerSyncSHA256Hex(fileAt: snapshot)
        guard actualChecksum == checksum else {
            throw providerSyncDescriptorError(
                "Provider 恢复点 SQLite 摘要不一致"
            )
        }
        let integrity = try SQLiteDatabaseDriver(
            url: snapshot,
            readOnly: true
        ).readRows("PRAGMA quick_check;") {
            $0.text(0) ?? "unknown"
        }.joined(separator: ",")
        guard integrity == "ok" else {
            throw providerSyncDescriptorError(
                "Provider 恢复点 SQLite 完整性失败：\(integrity)"
            )
        }
        try backupRoot.directory.verifyRootPathIdentity()
        return ProviderSyncMetadataBackup(
            url: canonicalBackup,
            sqliteSnapshot: snapshot,
            checksum: checksum
        )
    }

    /// Automatic compensation owns only model_provider cells, never the whole database.
    /// Compare before writing; new rows, other columns and other tables remain intact.
    func restoreProviderMetadataColumns(
        _ backup: ProviderSyncMetadataBackup,
        sqliteDirectory: ProviderSyncHomeDirectory,
        expectedProviders: [String: String]? = nil,
        expectedProvider: String? = nil
    ) throws {
        try rejectMutationIfCodexIsRunning(operation: "Provider 自动补偿")
        guard try providerSyncSHA256Hex(fileAt: backup.sqliteSnapshot) == backup.checksum else {
            throw providerSyncDescriptorError("Provider 恢复点摘要变化，已保留恢复点并停止自动补偿")
        }
        let rows = try SQLiteDatabaseDriver(url: backup.sqliteSnapshot, readOnly: true).withConnection { database in
            guard let columns = try readThreadsTableColumns(database: database), columns.modelProvider else {
                return [(String, String?)]()
            }
            return try database.readRows("SELECT id, model_provider FROM threads;") { ($0.text(0) ?? "", $0.text(1)) }
        }
        _ = try withBoundDatabase(homeDirectory: sqliteDirectory, readOnly: false) { database, bound in
            try database.execute("BEGIN IMMEDIATE;")
            do {
                try rejectMutationIfCodexIsRunning(operation: "Provider 自动补偿")
                try sqliteDirectory.verifyBoundFile(bound)
                for (id, original) in rows {
                    guard let expected = expectedProviders?[id] ?? expectedProvider, original != expected else { continue }
                    let current = try database.readRows("SELECT model_provider FROM threads WHERE id = ?1;", bindings: [.text(id)]) { $0.text(0) }
                    guard let currentValue = current.first else { continue } // An external deletion is not ours to reverse.
                    guard currentValue == original || currentValue == expected else {
                        throw providerSyncDescriptorError("Provider 元数据已被其他写入修改，停止自动补偿；恢复点：\(backup.url.path)")
                    }
                    if currentValue == expected {
                        try database.execute("UPDATE threads SET model_provider = ?2 WHERE id = ?1;", bindings: [.text(id), .optionalText(original)])
                    }
                }
                try rejectMutationIfCodexIsRunning(operation: "Provider 自动补偿提交")
                try sqliteDirectory.verifyBoundFile(bound)
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        }
    }

    func restoreProviderMetadataBackup(
        _ backup: ProviderSyncMetadataBackup,
        sqliteDirectory: ProviderSyncHomeDirectory
    ) throws {
        let actualChecksum = try providerSyncSHA256Hex(
            fileAt: backup.sqliteSnapshot
        )
        guard actualChecksum == backup.checksum else {
            throw providerSyncDescriptorError(
                "写入前 Provider SQLite 恢复点摘要发生变化"
            )
        }
        _ = try withBoundDatabase(
            homeDirectory: sqliteDirectory,
            readOnly: false
        ) { database, bound in
            try sqliteDirectory.verifyBoundFile(bound)
            try rejectMutationIfCodexIsRunning(operation: "恢复 Provider 元数据")
            try database.restoreDatabase(from: backup.sqliteSnapshot)
            try sqliteDirectory.verifyBoundFile(bound)
            let integrity = try database.readRows("PRAGMA quick_check;") {
                $0.text(0) ?? "unknown"
            }.joined(separator: ",")
            guard integrity == "ok" else {
                throw providerSyncDescriptorError(
                    "恢复后的 SQLite 完整性失败：\(integrity)"
                )
            }
        }
    }
}
