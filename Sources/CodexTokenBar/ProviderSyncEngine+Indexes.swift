import Foundation

extension ProviderSyncEngine {
    func sqliteIntegrity(homeDirectory: ProviderSyncHomeDirectory) throws -> String {
        try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, _ in
            try queryRows(database: database, sql: "PRAGMA integrity_check;") { statement in
                sqliteText(statement, 0) ?? "unknown"
            }.first ?? "unknown"
        } ?? "missing"
    }

    func reconcileSessionIndex(homeDirectory: ProviderSyncHomeDirectory) throws -> Int {
        guard let rows = try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true, body: { database, _ in
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
        }) else { return 0 }

        let index = try homeDirectory.pinFile(
            relativePath: "session_index.jsonl",
            createParents: false
        )
        let existingSnapshot = try homeDirectory.entryMetadata(index) == nil
            ? nil
            : homeDirectory.readRegularFile(index, requireSingleLink: true)
        let existing = try readSessionIndexLines(data: existingSnapshot?.data)
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
        if let existingSnapshot {
            let replacement = try homeDirectory.replaceRegularFile(
                index,
                expectedIdentity: existingSnapshot.identity,
                data: output,
                preserving: existingSnapshot.metadata,
                beforeExchange: {
                    try self.sessionIndexWillReplace?(index.displayURL)
                }
            )
            try homeDirectory.commitRegularFileReplacement(replacement)
        } else {
            _ = try homeDirectory.createRegularFileAtomically(
                index,
                data: output,
                beforePlacement: {
                    try self.sessionIndexWillReplace?(index.displayURL)
                }
            )
        }
        return missingRows.count
    }

    func makeSessionIndexLine(
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

    func readSessionIndexIDs(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> (ids: Set<String>, rows: Int) {
        let result = try readSessionIndexLines(homeDirectory: homeDirectory)
        return (result.ids, result.rows)
    }

    func readSessionIndexLines(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> ProviderSyncSessionIndexLines {
        try readSessionIndexLines(
            data: homeDirectory.readOptionalRegularFile(
                relativePath: "session_index.jsonl",
                requireSingleLink: true
            )?.data
        )
    }

    private func readSessionIndexLines(data: Data?) throws -> ProviderSyncSessionIndexLines {
        guard let data else {
            return ProviderSyncSessionIndexLines(lines: [], ids: [], rows: 0)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw providerSyncDescriptorError("session_index.jsonl 不是 UTF-8")
        }
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

    func sessionIndexLineInfo(_ line: String) -> (id: String, updatedAtMilliseconds: Int64)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            return nil
        }
        return (id, parseISO8601Milliseconds(object["updated_at"] as? String))
    }

    func parseISO8601Milliseconds(_ value: String?) -> Int64 {
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

    func readWorkspaceOrderIssues(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> [ProviderSyncWorkspaceIssue] {
        guard let snapshot = try homeDirectory.readOptionalRegularFile(
            relativePath: ".codex-global-state.json",
            requireSingleLink: true
        ),
              let object = try readGlobalStateObject(data: snapshot.data),
              let projectOrder = object["project-order"] as? [String] else {
            return []
        }

        let threadCounts = try readActiveThreadCountsByCwd(homeDirectory: homeDirectory)
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

    func readVisibilitySummary(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> ProviderSyncVisibilitySummary {
        let globalSnapshot = try homeDirectory.readOptionalRegularFile(
            relativePath: ".codex-global-state.json",
            requireSingleLink: true
        )
        let globalObject = try globalSnapshot.flatMap { try readGlobalStateObject(data: $0.data) } ?? [:]
        let activeWorkspacePath = (globalObject["active-workspace-roots"] as? [String])?.first
        let labels = globalObject["electron-workspace-root-labels"] as? [String: String] ?? [:]

        return try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, _ in
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
        } ?? ProviderSyncVisibilitySummary(activeWorkspacePath: activeWorkspacePath)
    }

    func reconcileWorkspaceOrder(homeDirectory: ProviderSyncHomeDirectory) throws -> Int {
        let globalState = try homeDirectory.pinFile(
            relativePath: ".codex-global-state.json",
            createParents: false
        )
        guard let globalSnapshot = try homeDirectory.entryMetadata(globalState) == nil
                ? nil
                : homeDirectory.readRegularFile(globalState, requireSingleLink: true),
              var object = try readGlobalStateObject(data: globalSnapshot.data) else {
            return 0
        }

        var projectOrder = object["project-order"] as? [String] ?? []
        let existing = Set(projectOrder)
        let threadCounts = try readActiveThreadCountsByCwd(homeDirectory: homeDirectory)
        let missing = workspaceRootCandidates(from: object).filter { path in
            (threadCounts[path] ?? 0) > 0 && !existing.contains(path)
        }
        guard !missing.isEmpty else { return 0 }

        projectOrder.append(contentsOf: missing)
        object["project-order"] = projectOrder
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let companionBackup = try homeDirectory.pinFile(
            relativePath: ".codex-global-state.json.bak",
            createParents: false
        )
        let companionSnapshot = try homeDirectory.entryMetadata(companionBackup) == nil
            ? nil
            : homeDirectory.readRegularFile(companionBackup, requireSingleLink: true)
        try globalStateWillReplace?(globalState.displayURL)
        try homeDirectory.verifyParent(globalState)
        try homeDirectory.verifyParent(companionBackup)

        var replacements: [ProviderSyncRegularFileReplacement] = []
        do {
            replacements.append(try homeDirectory.replaceRegularFile(
                globalState,
                expectedIdentity: globalSnapshot.identity,
                data: data,
                preserving: globalSnapshot.metadata
            ))
            if let companionSnapshot {
                replacements.append(try homeDirectory.replaceRegularFile(
                    companionBackup,
                    expectedIdentity: companionSnapshot.identity,
                    data: data,
                    preserving: companionSnapshot.metadata
                ))
            }
        } catch let replacementError {
            var rollbackFailures: [String] = []
            for replacement in replacements.reversed() {
                do {
                    try homeDirectory.rollbackRegularFileReplacement(replacement)
                } catch {
                    rollbackFailures.append(
                        "\(replacement.file.displayURL.path)：\(error.localizedDescription)"
                    )
                }
            }
            guard rollbackFailures.isEmpty else {
                throw ProviderSyncIdentityConflictError(
                    message: "global-state replacement 失败且 rollback 不完整：\(replacementError.localizedDescription)",
                    recoveryPaths: rollbackFailures
                )
            }
            throw replacementError
        }
        for replacement in replacements {
            try homeDirectory.commitRegularFileReplacement(replacement)
        }
        return missing.count
    }

    func readGlobalStateObject(data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    func workspaceRootCandidates(from object: [String: Any]) -> [String] {
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

    func readActiveThreadCountsByCwd(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> [String: Int] {
        guard let counts = try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true, body: { database, _ in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return [String: Int]()
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
        }) else { return [:] }
        return counts
    }

    func readThreadsTableColumns(database: SQLiteDatabaseConnection) throws -> ProviderSyncSQLiteThreadColumns? {
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

    func threadsRepairWhereClause(columns: ProviderSyncSQLiteThreadColumns) -> String? {
        var predicates: [String] = []
        if columns.modelProvider {
            predicates.append("COALESCE(model_provider, '') <> ?1")
        }
        return predicates.isEmpty ? nil : predicates.joined(separator: " OR ")
    }

    func threadsRepairSetClause(columns: ProviderSyncSQLiteThreadColumns) -> String? {
        var assignments: [String] = []
        if columns.modelProvider {
            assignments.append("model_provider = ?1")
        }
        return assignments.isEmpty ? nil : assignments.joined(separator: ", ")
    }

    func threadListPreviewExpression(columns: ProviderSyncSQLiteThreadColumns) -> String {
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

    func sqliteUpdatedAtMillisecondsExpression(columns: ProviderSyncSQLiteThreadColumns) -> String {
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
}
