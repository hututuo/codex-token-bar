import Foundation

extension ProviderSyncEngine {
    func createBackup(codexHome: URL, sessionFiles: [URL], targetProvider: String) throws -> URL {
        let root = backupRootDirectory()
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
        try createSessionTar(
            files: sessionFiles,
            relativeTo: codexHome,
            destination: backup.appendingPathComponent("session-jsonl.before.tar")
        )

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

    func copyIfExists(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    func backupSQLiteDatabase(source: URL, destination: URL) throws {
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

    func createSessionTar(files: [URL], relativeTo codexHome: URL, destination: URL) throws {
        let canonicalHome = canonicalBackupHome(codexHome)
        let members = try files.map { file -> String in
            let resolvedFile = canonicalArchiveURL(file)
            guard isURL(resolvedFile, containedBy: canonicalHome) else {
                throw backupArchiveError("会话文件不在当前 Codex Home 内：\(file.path)")
            }
            let relativePath = String(resolvedFile.path.dropFirst(canonicalHome.path.count + 1))
            guard isScopedSessionPath(relativePath) else {
                throw backupArchiveError("会话文件路径不在允许范围内：\(relativePath)")
            }
            let values = try resolvedFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw backupArchiveError("会话文件不是常规文件：\(relativePath)")
            }
            return relativePath
        }.sorted()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-C", canonicalHome.path, "-cf", destination.path]
            + (members.isEmpty ? ["-T", "/dev/null"] : members)
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar failed"
            throw NSError(domain: "CodexTokenBar", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func latestBackupDirectory(for codexHome: URL) throws -> URL {
        guard let latest = backupDirectories(for: codexHome).first else {
            throw NSError(domain: "CodexTokenBar", code: 404, userInfo: [NSLocalizedDescriptionKey: "当前 Codex Home 没有可回滚的备份"])
        }
        return latest
    }

    func backupRecords(for codexHome: URL) -> [ProviderSyncBackupRecord] {
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

    func backupDirectories(for codexHome: URL) -> [URL] {
        let root = backupRootDirectory()
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

    func backupMetadata(_ backup: URL) -> (createdAt: Date?, targetProvider: String?, sessionFileCount: Int?) {
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

    func backupMatchesCodexHome(_ backup: URL, codexHome: URL) -> Bool {
        let manifest = backup.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backedUpHome = object["codex_home"] as? String else {
            return false
        }
        return canonicalBackupHome(URL(fileURLWithPath: backedUpHome)).path == canonicalBackupHome(codexHome).path
    }

    func restoreBackup(_ backup: URL, codexHome: URL) throws {
        guard backupMatchesCodexHome(backup, codexHome: codexHome) else {
            throw NSError(domain: "CodexTokenBar", code: 400, userInfo: [NSLocalizedDescriptionKey: "备份不属于当前 Codex Home，已拒绝回滚"])
        }

        let canonicalHome = canonicalBackupHome(codexHome)
        let stagedArchive = try stageSessionArchiveIfPresent(
            backup.appendingPathComponent("session-jsonl.before.tar"),
            backup: backup,
            canonicalHome: canonicalHome
        )
        defer {
            if let stagedArchive {
                try? fileManager.removeItem(at: stagedArchive.root)
            }
        }

        try restoreFileIfBackedUp(backup.appendingPathComponent("config.toml.before"), to: canonicalHome.appendingPathComponent("config.toml"), removeIfMissing: false)
        let state = canonicalHome.appendingPathComponent("state_5.sqlite")
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("state_5.sqlite.before"), to: state, removeIfMissing: false)
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("session_index.jsonl.before"), to: canonicalHome.appendingPathComponent("session_index.jsonl"), removeIfMissing: true)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.before"), to: canonicalHome.appendingPathComponent(".codex-global-state.json"), removeIfMissing: false)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.bak.before"), to: canonicalHome.appendingPathComponent(".codex-global-state.json.bak"), removeIfMissing: false)

        if let stagedArchive {
            for member in stagedArchive.members {
                try restoreFileIfBackedUp(
                    stagedArchive.root.appendingPathComponent(member.archivePath),
                    to: canonicalHome.appendingPathComponent(member.relativePath),
                    removeIfMissing: false
                )
            }
        }
    }

    private func stageSessionArchiveIfPresent(
        _ archive: URL,
        backup: URL,
        canonicalHome: URL
    ) throws -> ProviderSyncStagedSessionArchive? {
        guard fileManager.fileExists(atPath: archive.path) else {
            if (backupMetadata(backup).sessionFileCount ?? 0) > 0 {
                throw backupArchiveError("备份声明包含会话文件，但会话归档缺失")
            }
            return nil
        }

        let members = try validatedSessionArchiveMembers(archive, canonicalHome: canonicalHome)
        let stagingRoot = backup.deletingLastPathComponent()
            .appendingPathComponent(".provider-restore-stage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let canonicalStagingRoot = canonicalArchiveURL(stagingRoot)
        do {
            try runTar(arguments: [
                "-C", canonicalStagingRoot.path,
                "-xf", archive.path,
                "--no-same-owner",
                "--no-same-permissions"
            ])
            try validateStagedArchive(canonicalStagingRoot, members: members)
            return ProviderSyncStagedSessionArchive(root: canonicalStagingRoot, members: members)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    private func validatedSessionArchiveMembers(
        _ archive: URL,
        canonicalHome: URL
    ) throws -> [ProviderSyncSessionArchiveMember] {
        let memberLines = try tarOutput(arguments: ["-tf", archive.path])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let verboseLines = try tarOutput(arguments: ["-tvf", archive.path])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard memberLines.count == verboseLines.count else {
            throw backupArchiveError("归档成员清单无法可靠解析")
        }

        var seenArchivePaths = Set<String>()
        var seenRelativePaths = Set<String>()
        let legacyHomePrefix = String(canonicalHome.path.dropFirst()) + "/"
        return try zip(memberLines, verboseLines).map { archivePath, verboseLine in
            guard verboseLine.first == "-" else {
                throw backupArchiveError("归档成员不是常规文件：\(archivePath)")
            }
            guard !archivePath.hasPrefix("/"),
                  !archivePath.hasPrefix("./"),
                  isLexicallySafeArchivePath(archivePath),
                  seenArchivePaths.insert(archivePath).inserted else {
                throw backupArchiveError("归档成员路径无效或重复：\(archivePath)")
            }

            let relativePath: String
            if isScopedSessionPath(archivePath) {
                relativePath = archivePath
            } else if archivePath.hasPrefix(legacyHomePrefix) {
                relativePath = String(archivePath.dropFirst(legacyHomePrefix.count))
            } else {
                throw backupArchiveError("归档成员超出当前 Codex Home：\(archivePath)")
            }
            guard isScopedSessionPath(relativePath),
                  seenRelativePaths.insert(relativePath).inserted else {
                throw backupArchiveError("归档成员不在允许的会话范围或目标重复：\(archivePath)")
            }

            let destination = canonicalHome.appendingPathComponent(relativePath)
            let canonicalDestination = canonicalArchiveURL(destination)
            guard isURL(canonicalDestination, containedBy: canonicalHome) else {
                throw backupArchiveError("归档成员目标解析到 Codex Home 之外：\(archivePath)")
            }
            return ProviderSyncSessionArchiveMember(
                archivePath: archivePath,
                relativePath: relativePath
            )
        }
    }

    private func validateStagedArchive(
        _ stagingRoot: URL,
        members: [ProviderSyncSessionArchiveMember]
    ) throws {
        let expectedFiles = Set(members.map(\.archivePath))
        var stagedFiles = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw backupArchiveError("无法读取归档 staging 目录")
        }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            let canonicalItem = canonicalArchiveURL(item)
            guard isURL(canonicalItem, containedBy: stagingRoot) else {
                throw backupArchiveError("staging 成员解析到临时目录之外：\(item.path)")
            }
            let relativePath = String(canonicalItem.path.dropFirst(stagingRoot.path.count + 1))
            if values.isSymbolicLink == true {
                throw backupArchiveError("staging 中出现符号链接：\(relativePath)")
            }
            if values.isRegularFile == true {
                guard expectedFiles.contains(relativePath) else {
                    throw backupArchiveError("staging 中出现意外文件：\(relativePath)")
                }
                stagedFiles.insert(relativePath)
            } else if values.isDirectory != true {
                throw backupArchiveError("staging 中出现非常规成员：\(relativePath)")
            }
        }
        guard stagedFiles == expectedFiles else {
            throw backupArchiveError("staging 文件与已验证归档成员不一致")
        }
    }

    private func tarOutput(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: outputData, encoding: .utf8) ?? "tar failed"
            throw backupArchiveError(message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func runTar(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let diagnostics = Pipe()
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        try process.run()
        let diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, diagnosticData.isEmpty else {
            let message = String(data: diagnosticData, encoding: .utf8) ?? "tar failed"
            throw backupArchiveError(message)
        }
    }

    private func canonicalBackupHome(_ codexHome: URL) -> URL {
        canonicalArchiveURL(codexHome)
    }

    private func canonicalArchiveURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let canonicalPath = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: canonicalPath)
        }
        let parent = standardized.deletingLastPathComponent()
        guard parent.path != standardized.path else { return standardized }
        return canonicalArchiveURL(parent).appendingPathComponent(standardized.lastPathComponent)
    }

    private func isURL(_ candidate: URL, containedBy root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }

    private func isLexicallySafeArchivePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isScopedSessionPath(_ path: String) -> Bool {
        guard isLexicallySafeArchivePath(path), path.hasSuffix(".jsonl") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let root = components.first else { return false }
        return components.count >= 2 && (root == "sessions" || root == "archived_sessions")
    }

    private func backupArchiveError(_ message: String) -> NSError {
        NSError(
            domain: "CodexTokenBar",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "会话归档成员校验失败：\(message)"]
        )
    }

    func restoreFileIfBackedUp(_ source: URL, to destination: URL, removeIfMissing: Bool) throws {
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

    func removeSQLiteSidecars(for database: URL) throws {
        for suffix in ["-shm", "-wal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
    }
}

private struct ProviderSyncSessionArchiveMember {
    let archivePath: String
    let relativePath: String
}

private struct ProviderSyncStagedSessionArchive {
    let root: URL
    let members: [ProviderSyncSessionArchiveMember]
}
