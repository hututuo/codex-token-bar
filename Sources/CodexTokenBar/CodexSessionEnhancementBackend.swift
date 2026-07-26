// SPDX-License-Identifier: AGPL-3.0-only
// Behavior adapted from CodexPlusPlus v1.2.41 (BigPizzaV3), then rewritten
// for Codex Token Bar's Swift-native bridge. See OPEN_SOURCE_NOTICES.md.

import Darwin
import Foundation

struct CodexMarkdownExportPayload: Equatable, Sendable {
    let filename: String
    let message: String
}

typealias CodexMarkdownChunkEmitter = @Sendable (String) async throws -> Void

struct CodexWorkspaceMovePayload: Equatable, Sendable {
    let message: String
    let previousCwd: String
    let targetCwd: String
}

/// v2 起与 Tauri 端共用同一 JSON 形状（serde camelCase：threadId、
/// retainedOriginalRelativePath 全相对路径）与恢复语义：retained 文件契约为
/// "首行 = 原始 rollout 首行"（本端保留整文件、Tauri 端只保留首行，均满足），
/// 恢复判定与还原一律只使用 retained 首行。v1 时期两端格式互不兼容，读到即
/// 显式拒绝。
struct CodexWorkspaceMoveJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let codexHome: String
    let stateDatabase: String
    let threadID: String
    let rolloutRelativePath: String
    let retainedOriginalRelativePath: String
    let originalCwd: String
    let targetCwd: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case codexHome
        case stateDatabase
        case threadID = "threadId"
        case rolloutRelativePath
        case retainedOriginalRelativePath
        case originalCwd
        case targetCwd
    }
}

let codexWorkspaceMoveJournalSchemaVersion = 2

private struct CodexWorkspaceMoveJournalHandle {
    let journal: CodexWorkspaceMoveJournal
    let file: ProviderSyncPinnedFile
    let identity: ProviderSyncFileIdentity
}

protocol CodexSessionEnhancementExecuting: Sendable {
    func exportMarkdown(
        threadID: String,
        fallbackTitle: String,
        emit: @escaping CodexMarkdownChunkEmitter
    ) async throws -> CodexMarkdownExportPayload
    func moveThreadWorkspace(threadID: String, targetCwd: String) async throws -> CodexWorkspaceMovePayload
}

final class FoundationCodexSessionEnhancementExecutor: CodexSessionEnhancementExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTokenBar.SessionEnhancements")
    private let dataSourceResolver: @Sendable () -> CodexDataSource?

    init(
        dataSourceResolver: @escaping @Sendable () -> CodexDataSource? = {
            CodexDataSourceResolver().resolve()
        }
    ) {
        self.dataSourceResolver = dataSourceResolver
    }

    func exportMarkdown(
        threadID: String,
        fallbackTitle: String,
        emit: @escaping CodexMarkdownChunkEmitter
    ) async throws -> CodexMarkdownExportPayload {
        try CodexThreadID.validate(threadID)
        return try await Task.detached(priority: .userInitiated) { [dataSourceResolver] in
            guard let dataSource = dataSourceResolver() else {
                throw CodexSessionEnhancementBackendError.dataSourceUnavailable
            }
            return try await Self.exportMarkdown(
                threadID: threadID,
                fallbackTitle: fallbackTitle,
                dataSource: dataSource,
                fileManager: .default,
                emit: emit
            )
        }.value
    }

    func moveThreadWorkspace(
        threadID: String,
        targetCwd: String
    ) async throws -> CodexWorkspaceMovePayload {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [dataSourceResolver] in
                continuation.resume(with: Result {
                    try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance()
                    guard let dataSource = dataSourceResolver() else {
                        throw CodexSessionEnhancementBackendError.dataSourceUnavailable
                    }
                    return try Self.moveThreadWorkspace(
                        threadID: threadID,
                        targetCwd: targetCwd,
                        dataSource: dataSource,
                        fileManager: .default
                    )
                })
            }
        }
    }

    private static func exportMarkdown(
        threadID: String,
        fallbackTitle: String,
        dataSource: CodexDataSource,
        fileManager: FileManager,
        emit: @escaping CodexMarkdownChunkEmitter
    ) async throws -> CodexMarkdownExportPayload {
        let record = try threadRecord(threadID: threadID, dataSource: dataSource)
        let title = displayTitle(record.title.isEmpty ? fallbackTitle : record.title)
        let rolloutURL = try trustedRolloutURL(
            record.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        let filename = buildFilename(title: title, threadID: threadID)
        try await streamMarkdown(from: rolloutURL, title: title, emit: emit)
        return CodexMarkdownExportPayload(
            filename: filename,
            message: "已生成 Markdown：\(filename)"
        )
    }

    private static func moveThreadWorkspace(
        threadID: String,
        targetCwd: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> CodexWorkspaceMovePayload {
        let target = URL(fileURLWithPath: (targetCwd as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexSessionEnhancementBackendError.invalidTargetDirectory(target.path)
        }

        let canonicalHome = dataSource.codexHome.standardizedFileURL
            .resolvingSymlinksInPath()
        let homeDirectory = try ProviderSyncHomeDirectory(
            canonicalURL: canonicalHome
        )
        defer { try? homeDirectory.close() }
        try recoverInterruptedWorkspaceMove(
            threadID: threadID,
            dataSource: dataSource,
            codexHome: canonicalHome,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        let record = try threadRecord(threadID: threadID, dataSource: dataSource)
        let rolloutURL: URL?
        if record.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rolloutURL = nil
        } else {
            rolloutURL = try trustedRolloutURL(
                record.rolloutPath,
                dataSource: dataSource,
                fileManager: fileManager
            )
        }
        if record.cwd == target.path {
            return try finishNoopMoveWithDriftHeal(
                record: record,
                rolloutURL: rolloutURL,
                canonicalHome: canonicalHome,
                homeDirectory: homeDirectory,
                threadID: threadID,
                targetCwd: target.path
            )
        }
        let replacement: ProviderSyncRegularFileReplacement?
        let journalHandle: CodexWorkspaceMoveJournalHandle?
        if let rolloutURL {
            let rolloutRelativePath = try trustedRelativePath(
                for: rolloutURL,
                under: canonicalHome
            )
            // 漂移 fail closed（对齐 Tauri 端准备阶段检查）：rollout 首行与数据
            // 库指向不同目录时拒绝写 journal——否则崩溃后的恢复三方判定必然
            // 失配，该线程的移动会永久锁死。
            let rolloutFile = try homeDirectory.pinFile(
                relativePath: rolloutRelativePath,
                createParents: false
            )
            let firstLine = try homeDirectory.readRegularFileFirstLine(
                rolloutFile,
                requireSingleLink: true
            )
            let rolloutCwd = try workspaceMetadataCwd(
                firstLine.data,
                threadID: threadID
            )
            guard rolloutCwd == record.cwd else {
                throw CodexSessionEnhancementBackendError.workspaceMetadataDrift(
                    databaseCwd: record.cwd,
                    rolloutCwd: rolloutCwd
                )
            }
            let retainedOriginalName =
                ".provider-session-prefix-workspace-\(threadID)"
            let handle = try beginWorkspaceMoveJournal(
                CodexWorkspaceMoveJournal(
                    schemaVersion: codexWorkspaceMoveJournalSchemaVersion,
                    codexHome: canonicalHome.path,
                    stateDatabase: dataSource.stateDatabase.standardizedFileURL.path,
                    threadID: threadID,
                    rolloutRelativePath: rolloutRelativePath,
                    retainedOriginalRelativePath: retainedRelativePath(
                        rolloutRelativePath: rolloutRelativePath,
                        retainedOriginalName: retainedOriginalName
                    ),
                    originalCwd: record.cwd,
                    targetCwd: target.path
                ),
                homeDirectory: homeDirectory
            )
            do {
                replacement = try replaceWorkspaceMetadataFirstLine(
                    rolloutURL: rolloutURL,
                    codexHome: canonicalHome,
                    homeDirectory: homeDirectory,
                    threadID: threadID,
                    targetCwd: target.path,
                    retainedOriginalName: retainedOriginalName,
                    firstLine: firstLine
                )
                if replacement == nil {
                    try removeWorkspaceMoveJournal(
                        handle,
                        homeDirectory: homeDirectory
                    )
                    journalHandle = nil
                } else {
                    journalHandle = handle
                }
            } catch {
                do {
                    try recoverInterruptedWorkspaceMove(
                        threadID: threadID,
                        dataSource: dataSource,
                        codexHome: canonicalHome,
                        homeDirectory: homeDirectory,
                        fileManager: fileManager
                    )
                } catch let recoveryError {
                    throw ProviderSyncIdentityConflictError(
                        message: "准备项目移动失败且事务自动恢复失败：\(error.localizedDescription)；\(recoveryError.localizedDescription)",
                        recoveryPaths: [handle.file.displayURL.path]
                    )
                }
                throw error
            }
        } else {
            replacement = nil
            journalHandle = nil
        }

        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: false,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: 5_000
        )
        do {
            let changed = try database.executeChangedRows(
                """
                UPDATE threads
                SET cwd = ?1
                WHERE id = ?2
                  AND COALESCE(cwd, '') = ?3
                """,
                bindings: [
                    .text(target.path),
                    .text(threadID),
                    .text(record.cwd),
                ]
            )
            guard changed == 1 else {
                throw CodexSessionEnhancementBackendError
                    .workspaceChangedConcurrently(threadID)
            }
        } catch {
            if let replacement {
                do {
                    try homeDirectory.rollbackRegularFileReplacement(replacement)
                    try homeDirectory.syncParentDirectory(
                        of: replacement.file
                    )
                    if let journalHandle {
                        try removeWorkspaceMoveJournal(
                            journalHandle,
                            homeDirectory: homeDirectory
                        )
                    }
                } catch let rollbackError {
                    throw ProviderSyncIdentityConflictError(
                        message: "更新项目目录失败且 rollout 自动恢复失败：\(error.localizedDescription)；\(rollbackError.localizedDescription)",
                        recoveryPaths: [
                            replacement.file.displayURL.path,
                            replacement.file.displayURL.deletingLastPathComponent()
                                .appendingPathComponent(
                                    replacement.retainedOriginalName
                                ).path,
                        ]
                    )
                }
            }
            throw error
        }
        if let replacement {
            do {
                try homeDirectory.commitRegularFileReplacement(replacement)
            } catch {
                var rollbackFailures: [String] = []
                do {
                    let changed = try database.executeChangedRows(
                        """
                        UPDATE threads
                        SET cwd = ?1
                        WHERE id = ?2
                          AND COALESCE(cwd, '') = ?3
                        """,
                        bindings: [
                            .text(record.cwd),
                            .text(threadID),
                            .text(target.path),
                        ]
                    )
                    guard changed == 1 else {
                        throw CodexSessionEnhancementBackendError
                            .workspaceChangedConcurrently(threadID)
                    }
                } catch {
                    rollbackFailures.append(
                        "数据库恢复失败：\(error.localizedDescription)"
                    )
                }
                do {
                    try homeDirectory.rollbackRegularFileReplacement(replacement)
                    try homeDirectory.syncParentDirectory(
                        of: replacement.file
                    )
                } catch {
                    rollbackFailures.append(
                        "rollout 恢复失败：\(error.localizedDescription)"
                    )
                }
                guard rollbackFailures.isEmpty else {
                    throw ProviderSyncIdentityConflictError(
                        message: "提交 rollout 项目移动失败且补偿未完成：\(error.localizedDescription)；\(rollbackFailures.joined(separator: "；"))",
                        recoveryPaths: [
                            replacement.file.displayURL.path,
                            replacement.file.displayURL.deletingLastPathComponent()
                                .appendingPathComponent(
                                    replacement.retainedOriginalName
                                ).path,
                        ]
                    )
                }
                if let journalHandle {
                    try removeWorkspaceMoveJournal(
                        journalHandle,
                        homeDirectory: homeDirectory
                    )
                }
                throw ProviderSyncIdentityConflictError(
                    message: "提交 rollout 项目移动失败，已恢复数据库与 rollout：\(error.localizedDescription)",
                    recoveryPaths: [replacement.file.displayURL.path]
                )
            }
            do {
                try homeDirectory.syncParentDirectory(of: replacement.file)
            } catch {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动已提交，但 rollout 目录持久化确认失败：\(error.localizedDescription)",
                    recoveryPaths: [
                        journalHandle?.file.displayURL.path
                            ?? replacement.file.displayURL.path
                    ]
                )
            }
            if let journalHandle {
                try removeWorkspaceMoveJournal(
                    journalHandle,
                    homeDirectory: homeDirectory
                )
            }
        }

        return CodexWorkspaceMovePayload(
            message: "已移动对话",
            previousCwd: record.cwd,
            targetCwd: target.path
        )
    }

    private struct ThreadRecord {
        let title: String
        let cwd: String
        let rolloutPath: String
    }

    private struct ExportMessage {
        let speaker: String
        let timestamp: String?
        let body: String
    }

    private static func threadRecord(
        threadID: String,
        dataSource: CodexDataSource
    ) throws -> ThreadRecord {
        guard FileManager.default.fileExists(atPath: dataSource.stateDatabase.path) else {
            throw CodexSessionEnhancementBackendError.databaseUnavailable
        }
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: true,
            busyTimeoutMilliseconds: 5_000
        )
        let columns = Set(try database.readRows("PRAGMA table_info(threads)") { statement in
            statement.text(1) ?? ""
        })
        guard columns.contains("id"),
              columns.contains("title"),
              columns.contains("cwd"),
              columns.contains("rollout_path") else {
            throw CodexSessionEnhancementBackendError.unsupportedSchema
        }
        let rows = try database.readRows(
            "SELECT title, cwd, rollout_path FROM threads WHERE id = ?1 LIMIT 1",
            bindings: [.text(threadID)]
        ) { statement in
            ThreadRecord(
                title: statement.text(0) ?? "",
                cwd: statement.text(1) ?? "",
                rolloutPath: statement.text(2) ?? ""
            )
        }
        guard let record = rows.first else {
            throw CodexSessionEnhancementBackendError.threadNotFound(threadID)
        }
        return record
    }

    private static func trustedRolloutURL(
        _ rawPath: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexSessionEnhancementBackendError.rolloutPathMissing
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let candidate = (expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded)
            : dataSource.codexHome.appendingPathComponent(expanded)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let home = dataSource.codexHome.standardizedFileURL.resolvingSymlinksInPath()
        let homePrefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard resolved.path.hasPrefix(homePrefix),
              fileManager.fileExists(atPath: resolved.path) else {
            throw CodexSessionEnhancementBackendError.untrustedRolloutPath(resolved.path)
        }
        return resolved
    }

    private static func trustedRelativePath(
        for file: URL,
        under codexHome: URL
    ) throws -> String {
        let canonicalFile = file.standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = codexHome.path.hasSuffix("/")
            ? codexHome.path
            : codexHome.path + "/"
        guard canonicalFile.path.hasPrefix(prefix) else {
            throw CodexSessionEnhancementBackendError.untrustedRolloutPath(
                canonicalFile.path
            )
        }
        return String(canonicalFile.path.dropFirst(prefix.count))
    }

    private static func workspaceMoveJournalRelativePath(
        threadID: String
    ) -> String {
        "backups_state/codex-token-bar/workspace-move/\(threadID).json"
    }

    private static func beginWorkspaceMoveJournal(
        _ journal: CodexWorkspaceMoveJournal,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> CodexWorkspaceMoveJournalHandle {
        let file = try homeDirectory.pinFile(
            relativePath: workspaceMoveJournalRelativePath(
                threadID: journal.threadID
            ),
            createParents: true
        )
        guard try homeDirectory.entryMetadata(file) == nil else {
            throw ProviderSyncIdentityConflictError(
                message: "项目移动事务已存在，必须先自动恢复",
                recoveryPaths: [file.displayURL.path]
            )
        }
        let identity = try homeDirectory.createRegularFileAtomically(
            file,
            data: JSONEncoder().encode(journal)
        )
        try homeDirectory.syncParentDirectory(of: file)
        return CodexWorkspaceMoveJournalHandle(
            journal: journal,
            file: file,
            identity: identity
        )
    }

    private static func removeWorkspaceMoveJournal(
        _ handle: CodexWorkspaceMoveJournalHandle,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws {
        guard let metadata = try homeDirectory.entryMetadata(handle.file),
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              ProviderSyncFileIdentity(metadata) == handle.identity else {
            throw ProviderSyncIdentityConflictError(
                message: "拒绝删除身份已变化的项目移动事务",
                recoveryPaths: [handle.file.displayURL.path]
            )
        }
        try providerSyncUnlinkIfExists(
            directory: handle.file.parent.rawValue,
            name: handle.file.name
        )
        try homeDirectory.syncParentDirectory(of: handle.file)
    }

    private static func recoverInterruptedWorkspaceMove(
        threadID: String,
        dataSource: CodexDataSource,
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        fileManager: FileManager
    ) throws {
        let relativePath = workspaceMoveJournalRelativePath(
            threadID: threadID
        )
        let journalURL = codexHome.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: journalURL.path) else {
            return
        }
        let journalFile = try homeDirectory.pinFile(
            relativePath: relativePath,
            createParents: false
        )
        guard let metadata = try homeDirectory.entryMetadata(journalFile),
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= 64 * 1024 else {
            throw ProviderSyncIdentityConflictError(
                message: "项目移动事务文件无效",
                recoveryPaths: [journalFile.displayURL.path]
            )
        }
        let snapshot = try homeDirectory.readRegularFile(
            journalFile,
            expectedIdentity: ProviderSyncFileIdentity(metadata),
            requireSingleLink: true
        )
        let probe = try JSONSerialization.jsonObject(
            with: snapshot.data
        ) as? [String: Any]
        let probedVersion = probe?["schemaVersion"] as? Int
        guard probedVersion == codexWorkspaceMoveJournalSchemaVersion else {
            throw ProviderSyncIdentityConflictError(
                message: "项目移动事务版本不受支持（schemaVersion=\(probedVersion.map(String.init) ?? "缺失")）：v1 时期 Swift 与 Tauri 两端格式互不兼容，无法安全自动恢复；请用创建它的应用端完成恢复，或人工核对后删除",
                recoveryPaths: [journalFile.displayURL.path]
            )
        }
        let journal = try JSONDecoder().decode(
            CodexWorkspaceMoveJournal.self,
            from: snapshot.data
        )
        guard journal.threadID == threadID,
              journal.codexHome == codexHome.path,
              journal.stateDatabase
                == dataSource.stateDatabase.standardizedFileURL.path,
              journal.retainedOriginalRelativePath
                == retainedRelativePath(
                    rolloutRelativePath: journal.rolloutRelativePath,
                    retainedOriginalName:
                        ".provider-session-prefix-workspace-\(threadID)"
                ) else {
            throw ProviderSyncIdentityConflictError(
                message: "项目移动事务与当前数据源不匹配",
                recoveryPaths: [journalFile.displayURL.path]
            )
        }

        let currentFile = try homeDirectory.pinFile(
            relativePath: journal.rolloutRelativePath,
            createParents: false
        )
        let current = try homeDirectory.readRegularFileFirstLine(
            currentFile,
            requireSingleLink: true
        )
        let currentCwd = try workspaceMetadataCwd(
            current.data,
            threadID: threadID
        )
        let record = try threadRecord(
            threadID: threadID,
            dataSource: dataSource
        )
        let retainedFile = try homeDirectory.pinFile(
            relativePath: journal.retainedOriginalRelativePath,
            createParents: false
        )
        let retainedMetadata = try homeDirectory.entryMetadata(retainedFile)
        // 清掉上次恢复中断遗留的 .recovery 临时件，否则本次首行还原会因
        // O_EXCL 永久失败。
        let recoveryRemnant = try homeDirectory.pinFile(
            relativePath: "\(journal.retainedOriginalRelativePath).recovery",
            createParents: false
        )
        if try homeDirectory.entryMetadata(recoveryRemnant) != nil {
            try providerSyncUnlinkIfExists(
                directory: recoveryRemnant.parent.rawValue,
                name: recoveryRemnant.name
            )
            try homeDirectory.syncParentDirectory(of: recoveryRemnant)
        }

        if let retainedMetadata {
            guard (retainedMetadata.st_mode & S_IFMT) == S_IFREG,
                  retainedMetadata.st_nlink == 1 else {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动保留原件不是独立常规文件",
                    recoveryPaths: [retainedFile.displayURL.path]
                )
            }
            // v2 契约：retained 首行 = 原始 rollout 首行（本端整文件、Tauri 端
            // 仅首行都满足），判定与还原一律只取首行，回滚不再整文件 SWAP——
            // 既兼容两端 retained 形态，也保留 rollout 尾部与追加事件。
            let retained = try homeDirectory.readRegularFileFirstLine(
                retainedFile,
                expectedIdentity: ProviderSyncFileIdentity(retainedMetadata),
                requireSingleLink: true
            )
            let retainedCwd = try workspaceMetadataCwd(
                retained.data,
                threadID: threadID
            )
            if record.cwd == journal.originalCwd,
               currentCwd == journal.originalCwd,
               retainedCwd == journal.originalCwd {
                // 双方都未提交：丢弃 prepared 残留（下方统一删除）。
            } else if record.cwd == journal.originalCwd,
                      currentCwd == journal.targetCwd,
                      retainedCwd == journal.originalCwd {
                try restoreRolloutFirstLineDuringRecovery(
                    file: currentFile,
                    current: current,
                    replacementLine: retained.data,
                    homeDirectory: homeDirectory,
                    threadID: threadID
                )
            } else if record.cwd == journal.targetCwd,
                      currentCwd == journal.originalCwd,
                      retainedCwd == journal.originalCwd {
                try restoreRolloutFirstLineDuringRecovery(
                    file: currentFile,
                    current: current,
                    replacementLine: rewriteWorkspaceMetadataLine(
                        current.data,
                        threadID: threadID,
                        targetCwd: journal.targetCwd
                    ),
                    homeDirectory: homeDirectory,
                    threadID: threadID
                )
            } else if record.cwd == journal.targetCwd,
                      currentCwd == journal.targetCwd,
                      retainedCwd == journal.originalCwd {
                // 双方都已到目标：只需清理 retained。
            } else if record.cwd == journal.originalCwd,
                      currentCwd == journal.originalCwd,
                      retainedCwd == journal.targetCwd {
                // 本端 SWAP 中断残留：replacement 落在 retained 位置，直接丢弃。
            } else {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动事务中的 rollout 状态无法安全判定",
                    recoveryPaths: [
                        currentFile.displayURL.path,
                        retainedFile.displayURL.path,
                    ]
                )
            }
            try providerSyncUnlinkIfExists(
                directory: retainedFile.parent.rawValue,
                name: retainedFile.name
            )
            try homeDirectory.syncParentDirectory(of: retainedFile)
        } else {
            if record.cwd == journal.originalCwd,
               currentCwd == journal.targetCwd {
                try compareAndSetThreadCwd(
                    threadID: threadID,
                    from: journal.originalCwd,
                    to: journal.targetCwd,
                    dataSource: dataSource
                )
            } else if record.cwd == journal.targetCwd,
                      currentCwd == journal.originalCwd {
                guard let replacement =
                    try replaceWorkspaceMetadataFirstLine(
                        rolloutURL: currentFile.displayURL,
                        codexHome: codexHome,
                        homeDirectory: homeDirectory,
                        threadID: threadID,
                        targetCwd: journal.targetCwd,
                        retainedOriginalName:
                            ".provider-session-prefix-workspace-\(threadID)"
                    ) else {
                    throw ProviderSyncIdentityConflictError(
                        message: "项目移动恢复未产生预期 rollout replacement",
                        recoveryPaths: [currentFile.displayURL.path]
                    )
                }
                try homeDirectory.commitRegularFileReplacement(replacement)
                try homeDirectory.syncParentDirectory(of: currentFile)
            } else if !(
                (record.cwd == journal.originalCwd
                    && currentCwd == journal.originalCwd)
                || (record.cwd == journal.targetCwd
                    && currentCwd == journal.targetCwd)
            ) {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动事务缺少保留原件且数据库与 rollout 不一致",
                    recoveryPaths: [
                        journalFile.displayURL.path,
                        currentFile.displayURL.path,
                    ]
                )
            }
        }

        try removeWorkspaceMoveJournal(
            CodexWorkspaceMoveJournalHandle(
                journal: journal,
                file: journalFile,
                identity: snapshot.identity
            ),
            homeDirectory: homeDirectory
        )
    }

    private static func workspaceMetadataCwd(
        _ line: Data,
        threadID: String
    ) throws -> String {
        guard let event = try JSONSerialization.jsonObject(
            with: line
        ) as? [String: Any],
              event["type"] as? String == "session_meta",
              let payload = event["payload"] as? [String: Any],
              payload["id"] as? String == threadID else {
            throw CodexSessionEnhancementBackendError
                .rolloutMetadataMismatch(threadID)
        }
        return payload["cwd"] as? String ?? ""
    }

    private static func retainedRelativePath(
        rolloutRelativePath: String,
        retainedOriginalName: String
    ) -> String {
        let parentPath = (rolloutRelativePath as NSString).deletingLastPathComponent
        return parentPath.isEmpty
            ? retainedOriginalName
            : "\(parentPath)/\(retainedOriginalName)"
    }

    // 数据库已在目标目录时不能直接早退：rollout 首行可能仍指旧目录（历史漂移），
    // 一旦放过，漂移会被永久化，此后任何移动都会被漂移检查锁死且没有产品内
    // 出口。这里读首行核对，不一致就原位治愈。
    private static func finishNoopMoveWithDriftHeal(
        record: ThreadRecord,
        rolloutURL: URL?,
        canonicalHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        threadID: String,
        targetCwd: String
    ) throws -> CodexWorkspaceMovePayload {
        if let rolloutURL {
            let relativePath = try trustedRelativePath(
                for: rolloutURL,
                under: canonicalHome
            )
            let file = try homeDirectory.pinFile(
                relativePath: relativePath,
                createParents: false
            )
            let firstLine = try homeDirectory.readRegularFileFirstLine(
                file,
                requireSingleLink: true
            )
            let rolloutCwd = try workspaceMetadataCwd(
                firstLine.data,
                threadID: threadID
            )
            if rolloutCwd != targetCwd {
                let replacementLine = try rewriteWorkspaceMetadataLine(
                    firstLine.data,
                    threadID: threadID,
                    targetCwd: targetCwd
                )
                let replacement = try homeDirectory.replaceRegularFileFirstLine(
                    file,
                    expectedIdentity: firstLine.identity,
                    expectedLine: firstLine.data,
                    replacementLine: replacementLine,
                    preserving: firstLine.metadata,
                    retainedOriginalName:
                        ".provider-session-prefix-workspace-\(threadID)"
                )
                try homeDirectory.commitRegularFileReplacement(replacement)
                try homeDirectory.syncParentDirectory(of: file)
                return CodexWorkspaceMovePayload(
                    message: "会话已在目标项目目录；已修复 rollout 项目目录漂移",
                    previousCwd: record.cwd,
                    targetCwd: targetCwd
                )
            }
        }
        return CodexWorkspaceMovePayload(
            message: "会话已在目标项目目录",
            previousCwd: record.cwd,
            targetCwd: targetCwd
        )
    }

    private static func rewriteWorkspaceMetadataLine(
        _ line: Data,
        threadID: String,
        targetCwd: String
    ) throws -> Data {
        guard var event = try JSONSerialization.jsonObject(
            with: line
        ) as? [String: Any],
              event["type"] as? String == "session_meta",
              var payload = event["payload"] as? [String: Any],
              payload["id"] as? String == threadID else {
            throw CodexSessionEnhancementBackendError.rolloutMetadataMismatch(
                threadID
            )
        }
        payload["cwd"] = targetCwd
        event["payload"] = payload
        return try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys]
        )
    }

    // 恢复期首行还原：retained 主文件仍在时不能复用其名字做替换临时件，
    // 改用 .recovery 后缀临时名；commit 会清理该临时件，主 retained 由调用方
    // 在还原成功后另行删除。中断只会退回可再次收敛的既有状态。
    private static func restoreRolloutFirstLineDuringRecovery(
        file: ProviderSyncPinnedFile,
        current: ProviderSyncRegularFileFirstLineSnapshot,
        replacementLine: Data,
        homeDirectory: ProviderSyncHomeDirectory,
        threadID: String
    ) throws {
        let replacement = try homeDirectory.replaceRegularFileFirstLine(
            file,
            expectedIdentity: current.identity,
            expectedLine: current.data,
            replacementLine: replacementLine,
            preserving: current.metadata,
            retainedOriginalName:
                ".provider-session-prefix-workspace-\(threadID).recovery"
        )
        try homeDirectory.commitRegularFileReplacement(replacement)
        try homeDirectory.syncParentDirectory(of: file)
    }

    private static func compareAndSetThreadCwd(
        threadID: String,
        from originalCwd: String,
        to targetCwd: String,
        dataSource: CodexDataSource
    ) throws {
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: false,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: 5_000
        )
        let changed = try database.executeChangedRows(
            """
            UPDATE threads
            SET cwd = ?1
            WHERE id = ?2
              AND COALESCE(cwd, '') = ?3
            """,
            bindings: [
                .text(targetCwd),
                .text(threadID),
                .text(originalCwd),
            ]
        )
        guard changed == 1 else {
            throw CodexSessionEnhancementBackendError
                .workspaceChangedConcurrently(threadID)
        }
    }

    /// 单条 rollout 行的上限。合法 Codex 事件远小于该值；没有上限时，一个
    /// 无换行或单行数 GiB 的损坏文件会把整个文件累进内存，这正是流式导出
    /// 要消灭的工作集。超限视为文件损坏并明确失败，不做静默截断。
    static let maximumRolloutLineBytes = 64 * 1024 * 1024

    private static func streamMarkdown(
        from url: URL,
        title: String,
        emit: @escaping CodexMarkdownChunkEmitter
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var input = Data()
        var cursor = 0
        var messageCount = 0

        func emitLine(_ data: Data) async throws {
            guard let message = exportMessage(from: data) else { return }
            if messageCount > 0 {
                try await emit("\n\n")
            }
            messageCount += 1
            try await emit("### \(message.speaker)\n")
            if let timestamp = message.timestamp {
                try await emit("_\(timestamp)_\n")
            }
            try await emit("\n")
            try await emit(message.body)
        }

        try await emit("# \(title)\n\n")
        while let chunk = try handle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            input.append(chunk)
            while let newline = input[cursor...].firstIndex(of: 0x0A) {
                try await emitLine(Data(input[cursor..<newline]))
                cursor = newline + 1
            }
            guard input.count - cursor <= maximumRolloutLineBytes else {
                throw CodexSessionEnhancementBackendError
                    .oversizedRolloutLine(maximumRolloutLineBytes)
            }
            if cursor > 0, cursor >= 1024 * 1024 {
                input.removeSubrange(0..<cursor)
                cursor = 0
            }
        }
        if cursor < input.count {
            try await emitLine(Data(input[cursor...]))
        }
        guard messageCount > 0 else {
            throw CodexSessionEnhancementBackendError.noExportableMessages
        }
        try await emit("\n")
    }

    private static func exportMessage(from data: Data) -> ExportMessage? {
        // 无法解析为 JSON 的行（例如 Codex 正在写入的半行）与 Rust 端一致
        // 地跳过，不让单行噪声中断整场导出。
        guard !data.isEmpty,
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "response_item",
              let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let role = payload["role"] as? String,
              role == "user" || role == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        let body = content.compactMap(serializeContentBlock).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return ExportMessage(
            speaker: role == "user" ? "User" : "Assistant",
            timestamp: formattedTimestamp(event["timestamp"] as? String),
            body: body
        )
    }

    private static func serializeContentBlock(_ block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "input_text", "output_text":
            let text = (block["text"] as? String ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .newlines)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case "input_image":
            let imageURL = (block["image_url"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !imageURL.isEmpty, !imageURL.hasPrefix("data:") else {
                return "> Image attachment"
            }
            return "> Image attachment\n[Image link](<\(imageURL)>)"
        default:
            return nil
        }
    }

    private static func formattedTimestamp(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        return date.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    private static func displayTitle(_ value: String) -> String {
        let value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? "Untitled session" : value
    }

    private static func buildFilename(title: String, threadID: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { invalid.contains($0) ? " " : String($0) }.joined()
        var safeTitle = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        safeTitle = String(safeTitle.prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if safeTitle.isEmpty { safeTitle = "Untitled session" }
        return "\(safeTitle)-\(threadID).md"
    }

    private static func replaceWorkspaceMetadataFirstLine(
        rolloutURL: URL,
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        threadID: String,
        targetCwd: String,
        retainedOriginalName: String,
        firstLine presetFirstLine: ProviderSyncRegularFileFirstLineSnapshot? = nil
    ) throws -> ProviderSyncRegularFileReplacement? {
        let prefix = codexHome.path.hasSuffix("/")
            ? codexHome.path
            : codexHome.path + "/"
        guard rolloutURL.path.hasPrefix(prefix) else {
            throw CodexSessionEnhancementBackendError.untrustedRolloutPath(
                rolloutURL.path
            )
        }
        let relativePath = String(rolloutURL.path.dropFirst(prefix.count))
        let file = try homeDirectory.pinFile(
            relativePath: relativePath,
            createParents: false
        )
        // 调用方已做漂移检查时必须传入同一份首行快照：替换用它做 expectedLine，
        // 检查与替换之间的任何首行变化都会被拒绝，与 Tauri 端语义一致。
        let firstLine = try presetFirstLine ?? homeDirectory.readRegularFileFirstLine(
            file,
            requireSingleLink: true
        )
        guard var event = try JSONSerialization.jsonObject(
            with: firstLine.data
        ) as? [String: Any],
              event["type"] as? String == "session_meta",
              var payload = event["payload"] as? [String: Any],
              payload["id"] as? String == threadID else {
            throw CodexSessionEnhancementBackendError.rolloutMetadataMismatch(
                threadID
            )
        }
        guard payload["cwd"] as? String != targetCwd else { return nil }
        payload["cwd"] = targetCwd
        event["payload"] = payload
        let replacementLine = try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys]
        )
        return try homeDirectory.replaceRegularFileFirstLine(
            file,
            expectedIdentity: firstLine.identity,
            expectedLine: firstLine.data,
            replacementLine: replacementLine,
            preserving: firstLine.metadata,
            retainedOriginalName: retainedOriginalName
        )
    }
}

enum CodexSessionEnhancementBackendError: LocalizedError {
    case dataSourceUnavailable
    case databaseUnavailable
    case invalidTargetDirectory(String)
    case noExportableMessages
    case oversizedRolloutLine(Int)
    case rolloutPathMissing
    case rolloutMetadataMismatch(String)
    case threadNotFound(String)
    case unsupportedSchema
    case untrustedRolloutPath(String)
    case workspaceChangedConcurrently(String)
    case workspaceMetadataDrift(databaseCwd: String, rolloutCwd: String)

    var errorDescription: String? {
        switch self {
        case .dataSourceUnavailable:
            return "没有可用的 Codex 数据目录"
        case .databaseUnavailable:
            return "Codex 本地数据库不可用"
        case let .invalidTargetDirectory(path):
            return "目标项目目录不可用：\(path)"
        case .noExportableMessages:
            return "未找到可导出的用户或助手消息"
        case let .oversizedRolloutLine(limit):
            return "rollout 单行超过 \(limit / (1024 * 1024)) MiB 上限，文件可能已损坏"
        case .rolloutPathMissing:
            return "会话缺少 rollout 文件路径"
        case let .rolloutMetadataMismatch(threadID):
            return "rollout 首行不是目标会话元数据：\(threadID)"
        case let .threadNotFound(threadID):
            return "本地数据库中未找到会话：\(threadID)"
        case .unsupportedSchema:
            return "当前 Codex 本地存储结构不受支持"
        case let .untrustedRolloutPath(path):
            return "rollout 文件不存在或不在当前 Codex Home 内：\(path)"
        case let .workspaceChangedConcurrently(threadID):
            return "会话项目目录在操作期间已被其他进程修改：\(threadID)"
        case let .workspaceMetadataDrift(databaseCwd, rolloutCwd):
            return "rollout 与数据库的项目目录不一致，已拒绝覆盖：数据库=\(databaseCwd)，rollout=\(rolloutCwd)；可先移动到数据库所记目录以自动修复漂移"
        }
    }
}
