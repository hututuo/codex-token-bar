// SPDX-License-Identifier: AGPL-3.0-only
// Behavior adapted from CodexPlusPlus v1.2.41 (BigPizzaV3), then rewritten
// for Codex Token Bar's Swift-native bridge. See OPEN_SOURCE_NOTICES.md.

import Darwin
import Foundation

struct CodexMarkdownExportPayload: Equatable, Sendable {
    let filename: String
    let markdown: String
    let message: String
}

struct CodexWorkspaceMovePayload: Equatable, Sendable {
    let message: String
    let previousCwd: String
    let targetCwd: String
}

struct CodexWorkspaceMoveJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let codexHome: String
    let stateDatabase: String
    let threadID: String
    let rolloutRelativePath: String
    let retainedOriginalName: String
    let originalCwd: String
    let targetCwd: String
}

private struct CodexWorkspaceMoveJournalHandle {
    let journal: CodexWorkspaceMoveJournal
    let file: ProviderSyncPinnedFile
    let identity: ProviderSyncFileIdentity
}

protocol CodexSessionEnhancementExecuting: Sendable {
    func exportMarkdown(threadID: String, fallbackTitle: String) async throws -> CodexMarkdownExportPayload
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
        fallbackTitle: String
    ) async throws -> CodexMarkdownExportPayload {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [dataSourceResolver] in
                continuation.resume(with: Result {
                    guard let dataSource = dataSourceResolver() else {
                        throw CodexSessionEnhancementBackendError.dataSourceUnavailable
                    }
                    return try Self.exportMarkdown(
                        threadID: threadID,
                        fallbackTitle: fallbackTitle,
                        dataSource: dataSource,
                        fileManager: .default
                    )
                })
            }
        }
    }

    func moveThreadWorkspace(
        threadID: String,
        targetCwd: String
    ) async throws -> CodexWorkspaceMovePayload {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [dataSourceResolver] in
                continuation.resume(with: Result {
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
        fileManager: FileManager
    ) throws -> CodexMarkdownExportPayload {
        let record = try threadRecord(threadID: threadID, dataSource: dataSource)
        let title = displayTitle(record.title.isEmpty ? fallbackTitle : record.title)
        let rolloutURL = try trustedRolloutURL(
            record.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        let filename = buildFilename(title: title, threadID: threadID)
        return CodexMarkdownExportPayload(
            filename: filename,
            markdown: try renderMarkdown(from: rolloutURL, title: title),
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
        let replacement: ProviderSyncRegularFileReplacement?
        let journalHandle: CodexWorkspaceMoveJournalHandle?
        if let rolloutURL {
            let rolloutRelativePath = try trustedRelativePath(
                for: rolloutURL,
                under: canonicalHome
            )
            let retainedOriginalName =
                ".provider-session-prefix-workspace-\(threadID)"
            let handle = try beginWorkspaceMoveJournal(
                CodexWorkspaceMoveJournal(
                    schemaVersion: 1,
                    codexHome: canonicalHome.path,
                    stateDatabase: dataSource.stateDatabase.standardizedFileURL.path,
                    threadID: threadID,
                    rolloutRelativePath: rolloutRelativePath,
                    retainedOriginalName: retainedOriginalName,
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
                    retainedOriginalName: retainedOriginalName
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
        let journal = try JSONDecoder().decode(
            CodexWorkspaceMoveJournal.self,
            from: snapshot.data
        )
        guard journal.schemaVersion == 1,
              journal.threadID == threadID,
              journal.codexHome == codexHome.path,
              journal.stateDatabase
                == dataSource.stateDatabase.standardizedFileURL.path,
              journal.retainedOriginalName
                == ".provider-session-prefix-workspace-\(threadID)" else {
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
        let parentPath = (journal.rolloutRelativePath as NSString)
            .deletingLastPathComponent
        let retainedRelativePath = parentPath.isEmpty
            ? journal.retainedOriginalName
            : "\(parentPath)/\(journal.retainedOriginalName)"
        let retainedFile = try homeDirectory.pinFile(
            relativePath: retainedRelativePath,
            createParents: false
        )
        let retainedMetadata = try homeDirectory.entryMetadata(retainedFile)

        if let retainedMetadata {
            guard (retainedMetadata.st_mode & S_IFMT) == S_IFREG,
                  retainedMetadata.st_nlink == 1 else {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动保留原件不是独立常规文件",
                    recoveryPaths: [retainedFile.displayURL.path]
                )
            }
            let retained = try homeDirectory.readRegularFileFirstLine(
                retainedFile,
                expectedIdentity: ProviderSyncFileIdentity(retainedMetadata),
                requireSingleLink: true
            )
            let retainedCwd = try workspaceMetadataCwd(
                retained.data,
                threadID: threadID
            )
            if currentCwd == journal.targetCwd,
               retainedCwd == journal.originalCwd {
                let replacement = ProviderSyncRegularFileReplacement(
                    file: currentFile,
                    retainedOriginalName: journal.retainedOriginalName,
                    originalIdentity: retained.identity,
                    replacementIdentity: current.identity
                )
                if record.cwd == journal.targetCwd {
                    try homeDirectory.commitRegularFileReplacement(
                        replacement
                    )
                } else if record.cwd == journal.originalCwd {
                    try homeDirectory.rollbackRegularFileReplacement(
                        replacement
                    )
                } else {
                    throw CodexSessionEnhancementBackendError
                        .workspaceChangedConcurrently(threadID)
                }
                try homeDirectory.syncParentDirectory(of: currentFile)
            } else if currentCwd == journal.originalCwd,
                      retainedCwd == journal.targetCwd,
                      record.cwd == journal.originalCwd {
                try providerSyncUnlinkIfExists(
                    directory: retainedFile.parent.rawValue,
                    name: retainedFile.name
                )
                try homeDirectory.syncParentDirectory(of: retainedFile)
            } else {
                throw ProviderSyncIdentityConflictError(
                    message: "项目移动事务中的 rollout 状态无法安全判定",
                    recoveryPaths: [
                        currentFile.displayURL.path,
                        retainedFile.displayURL.path,
                    ]
                )
            }
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
                            journal.retainedOriginalName
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

    private static func compareAndSetThreadCwd(
        threadID: String,
        from originalCwd: String,
        to targetCwd: String,
        dataSource: CodexDataSource
    ) throws {
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: false,
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

    private static func renderMarkdown(
        from url: URL,
        title: String
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var input = Data()
        var cursor = 0
        var markdown = "# \(title)\n\n"
        var messageCount = 0

        func appendLine(_ data: Data) throws {
            guard let message = try exportMessage(from: data) else { return }
            messageCount += 1
            markdown.append("### \(message.speaker)\n")
            if let timestamp = message.timestamp {
                markdown.append("_\(timestamp)_\n")
            }
            markdown.append("\n")
            markdown.append(message.body)
            markdown.append("\n\n")
        }

        while let chunk = try handle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            input.append(chunk)
            while let newline = input[cursor...].firstIndex(of: 0x0A) {
                try appendLine(Data(input[cursor..<newline]))
                cursor = newline + 1
            }
            if cursor > 0, cursor >= 1024 * 1024 {
                input.removeSubrange(0..<cursor)
                cursor = 0
            }
        }
        if cursor < input.count {
            try appendLine(Data(input[cursor...]))
        }
        guard messageCount > 0 else {
            throw CodexSessionEnhancementBackendError.noExportableMessages
        }
        if markdown.hasSuffix("\n\n") {
            markdown.removeLast()
        }
        return markdown
    }

    private static func exportMessage(from data: Data) throws -> ExportMessage? {
        guard !data.isEmpty,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        retainedOriginalName: String
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
        let firstLine = try homeDirectory.readRegularFileFirstLine(
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
    case rolloutPathMissing
    case rolloutMetadataMismatch(String)
    case threadNotFound(String)
    case unsupportedSchema
    case untrustedRolloutPath(String)
    case workspaceChangedConcurrently(String)

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
        }
    }
}
