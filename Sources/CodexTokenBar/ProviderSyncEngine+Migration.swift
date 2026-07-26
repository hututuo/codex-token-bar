import Darwin
import Foundation

private struct ProviderSyncMigrationManifest: Codable {
    let schemaVersion: Int
    let backupKind: String
    let createdAt: String
    let codexHome: String
    let canonicalCodexHome: String
    let sqliteHome: String
    let targetProvider: String
    let sessionFileCount: Int
    let sessionMembers: [ProviderSyncMigrationMember]
    let sqliteSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case backupKind = "backup_kind"
        case createdAt = "created_at"
        case codexHome = "codex_home"
        case canonicalCodexHome = "canonical_codex_home"
        case sqliteHome = "sqlite_home"
        case targetProvider = "target_provider"
        case sessionFileCount = "session_file_count"
        case sessionMembers = "session_members"
        case sqliteSHA256 = "sqlite_sha256"
    }
}

private struct ProviderSyncMigrationMember: Codable {
    let path: String
    let sha256: String
    let prefixPath: String
    let retainedName: String

    enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case prefixPath = "prefix_path"
        case retainedName = "retained_name"
    }
}

private struct ProviderSyncMigrationBinding {
    let member: ProviderSyncMigrationMember
    let file: ProviderSyncPinnedFile
    let snapshot: ProviderSyncRegularFileFirstLineSnapshot
    let replacementLine: Data
}

private struct ProviderSyncMigrationBackup {
    let metadata: ProviderSyncMetadataBackup
    let manifest: ProviderSyncMigrationManifest
    let bindings: [ProviderSyncMigrationBinding]
}

enum ProviderMigrationJournalCommitPhase: String {
    case beforeRename
    case afterRename
    case afterRootSync
}

private enum ProviderMigrationJournalPhase: String {
    case prepared
    case committed
}

private enum ProviderMigrationJournalCommitOutcome {
    /// 提交标记已落盘且 root fsync 成功。
    case committed
    /// 提交标记确定未生效（磁盘 journal 仍为 prepared），可安全回滚。
    case notCommitted(String)
    /// 提交标记可能已生效（rename 已发出后失败或持久化未确认），禁止回滚。
    case uncertain(String)
}

private struct ProviderSyncMigrationJournal: Codable {
    let schemaVersion: Int
    let phase: String?
    let codexHome: String
    let sqliteHome: String
    let backupPath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phase
        case codexHome = "codex_home"
        case sqliteHome = "sqlite_home"
        case backupPath = "backup_path"
    }

    // v1 journal 无 phase 字段；未知取值也按 prepared（回滚方向）处理，安全。
    var effectivePhase: ProviderMigrationJournalPhase {
        guard let phase,
              let parsed = ProviderMigrationJournalPhase(rawValue: phase) else {
            return .prepared
        }
        return parsed
    }
}

extension ProviderSyncEngine {
    func migrateProviderHistory(
        codexHome: URL,
        expectedHomeIdentity: CodexHomeIdentity?,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?
    ) throws -> ProviderSyncSnapshot {
        return try withMutationLease(
            codexHome: codexHome,
            expectedHomeIdentity: expectedHomeIdentity
        ) { canonicalHome, homeDirectory in
            try rejectMutationIfCodexIsRunning(operation: "显式迁移")
            guard includeArchivedSessions else {
                throw providerSyncDescriptorError(
                    "显式历史迁移必须包含归档会话，避免只改 SQLite 而遗漏 archived_sessions"
                )
            }
            return try withProviderSQLiteHome(
                codexHome: canonicalHome,
                homeDirectory: homeDirectory
            ) { sqliteHome, sqliteDirectory in
                let explicitTarget = targetProviderOverride?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let explicitTarget, !explicitTarget.isEmpty else {
                    throw providerSyncDescriptorError(
                        "显式迁移必须手动填写目标 Provider"
                    )
                }
                try reconcileInterruptedProviderMigration(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory
                )
                let configuredProvider = try configProvider(
                    homeDirectory: homeDirectory
                )
                let initial = try makeReport(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    includeArchivedSessions: includeArchivedSessions,
                    targetProviderOverride: explicitTarget
                )
                let target = explicitTarget
                if configuredProvider != target,
                   !(target == "openai" && configuredProvider == nil) {
                    throw providerSyncDescriptorError(
                        "显式迁移到 \(target) 前，必须先在 config.toml 中明确设置同名 model_provider"
                    )
                }

                let candidates = initial.sessionRecords.filter {
                    $0.provider != target
                }
                let backup = try createProviderMigrationBackup(
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    sqliteHome: sqliteHome,
                    sqliteDirectory: sqliteDirectory,
                    targetProvider: target,
                    records: candidates
                )
                let journalURL = try writeProviderMigrationJournal(
                    codexHome: canonicalHome,
                    sqliteHome: sqliteHome,
                    backupURL: backup.metadata.url
                )
                var replacements: [ProviderSyncRegularFileReplacement] = []
                let verified: ProviderSyncReport
                let sqliteRowsChanged: Int

                // 准备阶段：journal 仍为 prepared，任何失败都可以安全回滚。
                do {
                    for binding in backup.bindings {
                        let replacement = try homeDirectory
                            .replaceRegularFileFirstLine(
                                binding.file,
                                expectedIdentity: binding.snapshot.identity,
                                expectedLine: binding.snapshot.data,
                                replacementLine: binding.replacementLine,
                                preserving: binding.snapshot.metadata,
                                retainedOriginalName: binding.member.retainedName,
                                beforeExchange: {
                                    try self.sessionReplacementWillExchange?(
                                        binding.file.displayURL
                                    )
                                }
                            )
                        replacements.append(replacement)
                    }

                    sqliteRowsChanged = try updateSQLite(
                        homeDirectory: sqliteDirectory,
                        targetProvider: target
                    )
                    verified = try makeReport(
                        codexHome: canonicalHome,
                        homeDirectory: homeDirectory,
                        sqliteHome: sqliteHome,
                        sqliteDirectory: sqliteDirectory,
                        includeArchivedSessions: includeArchivedSessions,
                        targetProviderOverride: target
                    )
                    guard verified.sessionFiles.count
                            == initial.sessionFiles.count,
                          verified.migrationCandidateCount == 0,
                          verified.invalidSessionFiles
                            == initial.invalidSessionFiles,
                          verified.sqliteProviders.allSatisfy({
                              $0.provider == target
                          }),
                          verified.sqliteIntegrity == "ok" else {
                        throw providerSyncDescriptorError(
                            "显式迁移写后验证失败"
                        )
                    }

                    for replacement in replacements {
                        try homeDirectory.commitRegularFileReplacement(
                            replacement
                        )
                    }
                } catch {
                    do {
                        try restoreProviderMigrationBackup(
                            backup,
                            homeDirectory: homeDirectory,
                            sqliteDirectory: sqliteDirectory
                        )
                        try removeProviderMigrationJournal(
                            codexHome: canonicalHome
                        )
                    } catch let recoveryError {
                        throw providerSyncDescriptorError(
                            "显式迁移失败且自动恢复未完成：\(error.localizedDescription)；恢复错误：\(recoveryError.localizedDescription)；journal 保留于 \(journalURL.path)"
                        )
                    }
                    throw providerSyncDescriptorError(
                        "显式迁移失败，已自动恢复：\(error.localizedDescription)"
                    )
                }

                // 提交阶段：数据已写入并通过验证；只有确定未生效才允许回滚。
                let commitNote: String?
                switch commitProviderMigrationJournal(
                    codexHome: canonicalHome,
                    sqliteHome: sqliteHome,
                    backupURL: backup.metadata.url
                ) {
                case .committed:
                    do {
                        try removeProviderMigrationJournal(
                            codexHome: canonicalHome
                        )
                        commitNote = nil
                    } catch {
                        commitNote = "journal 清理未完成（\(error.localizedDescription)），下次启动将自动清理并保留迁移结果"
                    }
                case .notCommitted(let detail):
                    do {
                        try restoreProviderMigrationBackup(
                            backup,
                            homeDirectory: homeDirectory,
                            sqliteDirectory: sqliteDirectory
                        )
                        try removeProviderMigrationJournal(
                            codexHome: canonicalHome
                        )
                    } catch let recoveryError {
                        throw providerSyncDescriptorError(
                            "显式迁移提交标记写入未生效且自动恢复未完成：\(detail)；恢复错误：\(recoveryError.localizedDescription)；journal 保留于 \(journalURL.path)"
                        )
                    }
                    throw providerSyncDescriptorError(
                        "显式迁移提交标记写入未生效，已自动恢复：\(detail)"
                    )
                case .uncertain(let detail):
                    commitNote = "数据已写入并通过完整性验证，但提交标记持久化未完成（\(detail)）；journal 保留于 \(journalURL.path)，下次启动将按相位自动收敛"
                }
                let baseStatus =
                    "显式迁移完成：仅改写 \(replacements.count) 个会话首行和 SQLite Provider"
                var next = snapshot(
                    from: verified,
                    status: commitNote.map { "\(baseStatus)；\($0)" } ?? baseStatus
                )
                next.changedSessionFiles = replacements.count
                next.sqliteRowsChanged = sqliteRowsChanged
                next.lastBackupPath = backup.metadata.url.path
                return next
            }
        }
    }

    func rollbackProviderMigrationBackup(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        backupURL: URL,
        status: String
    ) throws -> ProviderSyncSnapshot? {
        guard providerMigrationBackupKind(at: backupURL) else {
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
            let selected = try validatedProviderMigrationBackup(
                at: backupURL,
                codexHome: codexHome,
                sqliteHome: sqliteHome
            )
            let current = try makeReport(
                codexHome: codexHome,
                homeDirectory: homeDirectory,
                sqliteHome: sqliteHome,
                sqliteDirectory: sqliteDirectory,
                includeArchivedSessions: true,
                targetProviderOverride: nil
            )
            let selectedPaths = Set(
                selected.manifest.sessionMembers.map(\.path)
            )
            let preRollbackRecords = current.sessionRecords.filter { record in
                guard let relative = providerMigrationRelativePath(
                    record.file,
                    codexHome: codexHome
                ) else {
                    return false
                }
                return selectedPaths.contains(relative)
            }
            guard preRollbackRecords.count == selectedPaths.count else {
                throw providerSyncDescriptorError(
                    "回滚前无法为全部会话首行建立补偿恢复点"
                )
            }
            let preRollback = try createProviderMigrationBackup(
                codexHome: codexHome,
                homeDirectory: homeDirectory,
                sqliteHome: sqliteHome,
                sqliteDirectory: sqliteDirectory,
                targetProvider: "pre-rollback",
                records: preRollbackRecords
            )
            do {
                try restoreProviderMigrationBackup(
                    selected,
                    homeDirectory: homeDirectory,
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
                        "显式迁移回滚后的 SQLite 完整性失败"
                    )
                }
                var next = snapshot(from: report, status: status)
                next.lastBackupPath = backupURL.path
                return next
            } catch {
                do {
                    try restoreProviderMigrationBackup(
                        preRollback,
                        homeDirectory: homeDirectory,
                        sqliteDirectory: sqliteDirectory
                    )
                } catch let compensationError {
                    throw providerSyncDescriptorError(
                        "显式迁移回滚失败且补偿失败：\(error.localizedDescription)；\(compensationError.localizedDescription)"
                    )
                }
                throw providerSyncDescriptorError(
                    "显式迁移回滚失败，已恢复回滚前状态：\(error.localizedDescription)"
                )
            }
        }
    }

    func reconcileInterruptedProviderMigration(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        sqliteHome: URL,
        sqliteDirectory: ProviderSyncHomeDirectory
    ) throws {
        guard try hasInterruptedProviderMigration(codexHome: codexHome) else {
            return
        }
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let journalURL = providerMigrationJournalURL(
            codexHome: codexHome,
            backupRoot: backupRoot.url
        )
        guard !isCodexRunning() else {
            throw providerSyncDescriptorError(
                "检测到未完成的 Provider 迁移；请先退出 Codex，再执行自动恢复。journal：\(journalURL.path)"
            )
        }
        let journal = try JSONDecoder().decode(
            ProviderSyncMigrationJournal.self,
            from: providerSyncReadSmallRegularFile(
                at: journalURL,
                maximumBytes: 1024 * 1024
            )
        )
        guard journal.schemaVersion == 1 || journal.schemaVersion == 2,
              journal.codexHome == codexHome.path,
              journal.sqliteHome == sqliteHome.path else {
            throw providerSyncDescriptorError(
                "Provider 迁移 journal 与当前存储根不匹配：\(journalURL.path)"
            )
        }
        switch journal.effectivePhase {
        case .committed:
            // 提交标记已落盘：迁移已完成并通过写后验证，保留新状态，只清理 journal。
            try removeProviderMigrationJournal(codexHome: codexHome)
        case .prepared:
            let backup = try validatedProviderMigrationBackup(
                at: URL(fileURLWithPath: journal.backupPath),
                codexHome: codexHome,
                sqliteHome: sqliteHome
            )
            try restoreProviderMigrationBackup(
                backup,
                homeDirectory: homeDirectory,
                sqliteDirectory: sqliteDirectory
            )
            try removeProviderMigrationJournal(codexHome: codexHome)
        }
    }

    private func createProviderMigrationBackup(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        sqliteHome: URL,
        sqliteDirectory: ProviderSyncHomeDirectory,
        targetProvider: String,
        records: [ProviderSyncSessionRecord]
    ) throws -> ProviderSyncMigrationBackup {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let root = backupRoot.url
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let identifier = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let staging = root.appendingPathComponent(
            ".provider-migration-\(identifier)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(
            identifier,
            isDirectory: true
        )
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

        let sqliteSnapshot = staging.appendingPathComponent(
            "state_5.sqlite.before"
        )
        try backupSQLiteDatabase(
            homeDirectory: sqliteDirectory,
            destination: sqliteSnapshot
        )
        guard fileManager.fileExists(atPath: sqliteSnapshot.path) else {
            throw providerSyncDescriptorError(
                "当前 SQLite Home 缺少 state_5.sqlite"
            )
        }
        let sqliteChecksum = try providerSyncSHA256Hex(fileAt: sqliteSnapshot)

        var members: [ProviderSyncMigrationMember] = []
        var bindings: [ProviderSyncMigrationBinding] = []
        var seenPaths = Set<String>()
        let prefixesDirectory = staging.appendingPathComponent(
            "session-prefixes",
            isDirectory: true
        )
        if !records.isEmpty {
            try fileManager.createDirectory(
                at: prefixesDirectory,
                withIntermediateDirectories: false
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: prefixesDirectory.path
            )
        }
        for record in records.sorted(by: { $0.file.path < $1.file.path }) {
            guard let relativePath = providerMigrationRelativePath(
                record.file,
                codexHome: codexHome
            ), seenPaths.insert(relativePath).inserted else {
                throw providerSyncDescriptorError(
                    "迁移会话路径不在当前 Codex Home 或发生重复：\(record.file.path)"
                )
            }
            let pinned = try homeDirectory.pinFile(
                relativePath: relativePath,
                createParents: false
            )
            let snapshot = try homeDirectory.readRegularFileFirstLine(
                pinned,
                requireSingleLink: true
            )
            guard let replacementLine = try rewrittenSessionFirstLine(
                snapshot.data,
                targetProvider: targetProvider
            ) else {
                throw providerSyncDescriptorError(
                    "迁移候选首行已变化或不是 canonical session_meta：\(record.file.path)"
                )
            }
            var prefix = Data()
            prefix.append(snapshot.data)
            prefix.append(snapshot.separator)
            let prefixName = "\(UUID().uuidString).before"
            let prefixPath = "session-prefixes/\(prefixName)"
            let prefixURL = staging.appendingPathComponent(prefixPath)
            try prefix.write(to: prefixURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: prefixURL.path
            )
            try providerSyncFsyncRegularFile(at: prefixURL)
            let member = ProviderSyncMigrationMember(
                path: relativePath,
                sha256: providerSyncSHA256Hex(prefix),
                prefixPath: prefixPath,
                retainedName: ".provider-session-prefix-\(UUID().uuidString)"
            )
            members.append(member)
            bindings.append(
                ProviderSyncMigrationBinding(
                    member: member,
                    file: pinned,
                    snapshot: snapshot,
                    replacementLine: replacementLine
                )
            )
        }

        let manifest = ProviderSyncMigrationManifest(
            schemaVersion: 3,
            backupKind: "provider_migration",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            codexHome: codexHome.path,
            canonicalCodexHome: codexHome.path,
            sqliteHome: sqliteHome.path,
            targetProvider: targetProvider,
            sessionFileCount: members.count,
            sessionMembers: members,
            sqliteSHA256: sqliteChecksum
        )
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(
            to: manifestURL,
            options: [.atomic]
        )
        try providerSyncFsyncRegularFile(at: sqliteSnapshot)
        try providerSyncFsyncRegularFile(at: manifestURL)
        if !records.isEmpty {
            try providerSyncFsyncDirectory(at: prefixesDirectory)
        }
        try providerSyncFsyncDirectory(at: staging)
        try homeDirectory.verifyRootPathIdentity()
        try sqliteDirectory.verifyRootPathIdentity()
        try backupRoot.directory.verifyRootPathIdentity()
        try publishProviderBackup(
            staging: staging,
            destination: destination,
            backupRoot: backupRoot.directory
        )
        published = true
        return ProviderSyncMigrationBackup(
            metadata: ProviderSyncMetadataBackup(
                url: destination,
                sqliteSnapshot: destination.appendingPathComponent(
                    "state_5.sqlite.before"
                ),
                checksum: sqliteChecksum
            ),
            manifest: manifest,
            bindings: bindings
        )
    }

    private func restoreProviderMigrationBackup(
        _ backup: ProviderSyncMigrationBackup,
        homeDirectory: ProviderSyncHomeDirectory,
        sqliteDirectory: ProviderSyncHomeDirectory
    ) throws {
        var replacements: [ProviderSyncRegularFileReplacement] = []
        do {
            for member in backup.manifest.sessionMembers {
                let prefixURL = backup.metadata.url.appendingPathComponent(
                    member.prefixPath
                )
                let prefix = try providerSyncReadSmallRegularFile(
                    at: prefixURL,
                    maximumBytes: 8 * 1024 * 1024 + 2
                )
                guard providerSyncSHA256Hex(prefix) == member.sha256,
                      let parts = firstLineParts(in: prefix) else {
                    throw providerSyncDescriptorError(
                        "迁移恢复点首行摘要无效：\(member.path)"
                    )
                }
                let file = try homeDirectory.pinFile(
                    relativePath: member.path,
                    createParents: false
                )
                let current = try homeDirectory.readRegularFileFirstLine(
                    file,
                    requireSingleLink: true
                )
                if current.data != parts.line {
                    let replacement = try homeDirectory
                        .replaceRegularFileFirstLine(
                            file,
                            expectedIdentity: current.identity,
                            expectedLine: current.data,
                            replacementLine: parts.line,
                            preserving: current.metadata
                        )
                    replacements.append(replacement)
                }
            }
            try restoreProviderMetadataBackup(
                backup.metadata,
                sqliteDirectory: sqliteDirectory
            )
            for replacement in replacements {
                try homeDirectory.commitRegularFileReplacement(replacement)
            }
            for member in backup.manifest.sessionMembers {
                let file = try homeDirectory.pinFile(
                    relativePath: member.path,
                    createParents: false
                )
                try homeDirectory.removeRetainedMigrationOriginalIfPresent(
                    file,
                    retainedName: member.retainedName
                )
            }
        } catch {
            var rollbackErrors: [String] = []
            for replacement in replacements.reversed() {
                do {
                    try homeDirectory.rollbackRegularFileReplacement(replacement)
                } catch {
                    rollbackErrors.append(error.localizedDescription)
                }
            }
            if rollbackErrors.isEmpty {
                throw error
            }
            throw providerSyncDescriptorError(
                "迁移恢复失败且首行补偿不完整：\(error.localizedDescription)；\(rollbackErrors.joined(separator: "；"))"
            )
        }
    }

    private func validatedProviderMigrationBackup(
        at backupURL: URL,
        codexHome: URL,
        sqliteHome: URL
    ) throws -> ProviderSyncMigrationBackup {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let canonicalRoot = backupRoot.url
        let canonicalBackup = try validatedProviderBackupDirectory(
            backupURL,
            canonicalRoot: canonicalRoot
        )
        let manifest = try JSONDecoder().decode(
            ProviderSyncMigrationManifest.self,
            from: providerSyncReadSmallRegularFile(
                at: canonicalBackup.appendingPathComponent("manifest.json"),
                maximumBytes: 64 * 1024 * 1024
            )
        )
        guard manifest.schemaVersion == 3,
              manifest.backupKind == "provider_migration",
              manifest.codexHome == codexHome.path,
              manifest.canonicalCodexHome == codexHome.path,
              manifest.sqliteHome == sqliteHome.path,
              manifest.sessionFileCount == manifest.sessionMembers.count else {
            throw providerSyncDescriptorError(
                "迁移恢复点 manifest 与当前存储根不匹配"
            )
        }
        var seenPaths = Set<String>()
        var seenPrefixes = Set<String>()
        for member in manifest.sessionMembers {
            guard providerMigrationRelativePathIsSafe(member.path),
                  member.prefixPath.hasPrefix("session-prefixes/"),
                  !member.prefixPath.contains(".."),
                  !member.prefixPath.contains("\\"),
                  member.retainedName.hasPrefix(".provider-session-prefix-"),
                  !member.retainedName.contains("/"),
                  seenPaths.insert(member.path).inserted,
                  seenPrefixes.insert(member.prefixPath).inserted else {
                throw providerSyncDescriptorError(
                    "迁移恢复点包含无效或重复成员"
                )
            }
            let prefix = try providerSyncReadSmallRegularFile(
                at: canonicalBackup.appendingPathComponent(member.prefixPath),
                maximumBytes: 8 * 1024 * 1024 + 2
            )
            guard providerSyncSHA256Hex(prefix) == member.sha256 else {
                throw providerSyncDescriptorError(
                    "迁移恢复点首行摘要不一致：\(member.path)"
                )
            }
        }
        let snapshot = canonicalBackup.appendingPathComponent(
            "state_5.sqlite.before"
        )
        let checksum = try providerSyncSHA256Hex(fileAt: snapshot)
        guard checksum == manifest.sqliteSHA256 else {
            throw providerSyncDescriptorError(
                "迁移恢复点 SQLite 摘要不一致"
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
                "迁移恢复点 SQLite 完整性失败：\(integrity)"
            )
        }
        try backupRoot.directory.verifyRootPathIdentity()
        return ProviderSyncMigrationBackup(
            metadata: ProviderSyncMetadataBackup(
                url: canonicalBackup,
                sqliteSnapshot: snapshot,
                checksum: checksum
            ),
            manifest: manifest,
            bindings: []
        )
    }

    private func providerMigrationBackupKind(at backupURL: URL) -> Bool {
        guard let data = try? providerSyncReadSmallRegularFile(
            at: backupURL.appendingPathComponent("manifest.json"),
            maximumBytes: 64 * 1024 * 1024
        ), let manifest = try? JSONDecoder().decode(
            ProviderSyncMigrationManifest.self,
            from: data
        ) else {
            return false
        }
        return manifest.schemaVersion == 3
            && manifest.backupKind == "provider_migration"
    }

    private func writeProviderMigrationJournal(
        codexHome: URL,
        sqliteHome: URL,
        backupURL: URL
    ) throws -> URL {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let journalURL = providerMigrationJournalURL(
            codexHome: codexHome,
            backupRoot: backupRoot.url
        )
        let journalFile = try backupRoot.directory.pinFile(
            relativePath: journalURL.lastPathComponent,
            createParents: false
        )
        guard try backupRoot.directory.entryMetadata(journalFile) == nil else {
            throw providerSyncDescriptorError(
                "Provider 迁移 journal 已存在，必须先完成恢复：\(journalURL.path)"
            )
        }
        let journal = ProviderSyncMigrationJournal(
            schemaVersion: 2,
            phase: ProviderMigrationJournalPhase.prepared.rawValue,
            codexHome: codexHome.path,
            sqliteHome: sqliteHome.path,
            backupPath: backupURL.path
        )
        _ = try backupRoot.directory.createRegularFileAtomically(
            journalFile,
            data: JSONEncoder().encode(journal)
        )
        try backupRoot.directory.syncRootDirectory()
        return journalURL
    }

    private func commitProviderMigrationJournal(
        codexHome: URL,
        sqliteHome: URL,
        backupURL: URL
    ) -> ProviderMigrationJournalCommitOutcome {
        let backupRoot: (url: URL, directory: ProviderSyncHomeDirectory)
        do {
            backupRoot = try openProviderBackupRoot()
        } catch {
            return .notCommitted(
                "打开 Provider 备份根失败：\(error.localizedDescription)"
            )
        }
        defer { try? backupRoot.directory.close() }
        let journalURL = providerMigrationJournalURL(
            codexHome: codexHome,
            backupRoot: backupRoot.url
        )
        var renameIssued = false
        var temporaryName: String?
        var parentDescriptor: Int32?
        do {
            let journalFile = try backupRoot.directory.pinFile(
                relativePath: journalURL.lastPathComponent,
                createParents: false
            )
            parentDescriptor = journalFile.parent.rawValue
            guard let metadata = try backupRoot.directory.entryMetadata(
                journalFile
            ), (metadata.st_mode & S_IFMT) == S_IFREG,
               metadata.st_nlink == 1 else {
                return .notCommitted(
                    "Provider 迁移 journal 缺失或不是独立常规文件：\(journalURL.path)"
                )
            }
            let journal = ProviderSyncMigrationJournal(
                schemaVersion: 2,
                phase: ProviderMigrationJournalPhase.committed.rawValue,
                codexHome: codexHome.path,
                sqliteHome: sqliteHome.path,
                backupPath: backupURL.path
            )
            let data = try JSONEncoder().encode(journal)
            let name = ".provider-migration-commit-\(UUID().uuidString).tmp"
            try providerSyncCreateRegularFile(
                directory: journalFile.parent.rawValue,
                name: name,
                data: data
            )
            temporaryName = name
            try providerMigrationJournalWillCommit?(.beforeRename)
            renameIssued = true
            try providerSyncRename(
                fromDirectory: journalFile.parent.rawValue,
                fromName: name,
                toDirectory: journalFile.parent.rawValue,
                toName: journalFile.name
            )
            temporaryName = nil
            try providerMigrationJournalWillCommit?(.afterRename)
            try backupRoot.directory.syncRootDirectory()
            try providerMigrationJournalWillCommit?(.afterRootSync)
            return .committed
        } catch {
            if let temporaryName, let parentDescriptor {
                try? providerSyncUnlinkIfExists(
                    directory: parentDescriptor,
                    name: temporaryName
                )
            }
            let detail = error.localizedDescription
            guard renameIssued else {
                return .notCommitted(detail)
            }
            // rename 已发出：重读磁盘 journal 判定真实终态。
            guard let data = try? providerSyncReadSmallRegularFile(
                at: journalURL,
                maximumBytes: 1024 * 1024
            ), let journal = try? JSONDecoder().decode(
                ProviderSyncMigrationJournal.self,
                from: data
            ) else {
                return .uncertain("\(detail)；journal 无法读取")
            }
            switch journal.effectivePhase {
            case .prepared:
                return .notCommitted(detail)
            case .committed:
                return .uncertain("\(detail)；提交标记已写入但持久化未确认")
            }
        }
    }

    func hasInterruptedProviderMigration(codexHome: URL) throws -> Bool {
        let requestedRoot = backupRootDirectory().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: requestedRoot.path,
            isDirectory: &isDirectory
        ) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw providerSyncDescriptorError(
                "Provider 备份根路径不是目录：\(requestedRoot.path)"
            )
        }
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let journalURL = providerMigrationJournalURL(
            codexHome: codexHome,
            backupRoot: backupRoot.url
        )
        var metadata = stat()
        if lstat(journalURL.path, &metadata) != 0 {
            if errno == ENOENT {
                return false
            }
            throw providerSyncPOSIXError(
                "无法读取 Provider 迁移 journal：\(journalURL.path)"
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw providerSyncDescriptorError(
                "Provider 迁移 journal 不是独立常规文件：\(journalURL.path)"
            )
        }
        try backupRoot.directory.verifyRootPathIdentity()
        return true
    }

    private func removeProviderMigrationJournal(
        codexHome: URL
    ) throws {
        let backupRoot = try openProviderBackupRoot()
        defer { try? backupRoot.directory.close() }
        let journalURL = providerMigrationJournalURL(
            codexHome: codexHome,
            backupRoot: backupRoot.url
        )
        let journalFile = try backupRoot.directory.pinFile(
            relativePath: journalURL.lastPathComponent,
            createParents: false
        )
        guard let metadata = try backupRoot.directory.entryMetadata(
            journalFile
        ) else {
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw providerSyncDescriptorError(
                "拒绝删除非独立常规 journal：\(journalURL.path)"
            )
        }
        try providerSyncUnlinkIfExists(
            directory: journalFile.parent.rawValue,
            name: journalFile.name
        )
        try backupRoot.directory.syncRootDirectory()
    }

    private func providerMigrationJournalURL(
        codexHome: URL,
        backupRoot: URL
    ) -> URL {
        let fingerprint = String(
            providerSyncSHA256Hex(Data(codexHome.path.utf8)).prefix(16)
        )
        return backupRoot.appendingPathComponent(
            ".provider-migration-active-\(fingerprint).json"
        )
    }
}

private func providerMigrationRelativePath(
    _ file: URL,
    codexHome: URL
) -> String? {
    let home = codexHome.standardizedFileURL.path
    let path = file.standardizedFileURL.path
    guard path.hasPrefix(home + "/") else {
        return nil
    }
    let relative = String(path.dropFirst(home.count + 1))
    return providerMigrationRelativePathIsSafe(relative) ? relative : nil
}

private func providerMigrationRelativePathIsSafe(_ relative: String) -> Bool {
    guard !relative.contains("\\"),
          !relative.hasPrefix("/"),
          relative.hasSuffix(".jsonl") else {
        return false
    }
    let components = relative.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard components.count >= 2,
          components.first == "sessions"
            || components.first == "archived_sessions" else {
        return false
    }
    return components.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
    }
}
