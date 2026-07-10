import CryptoKit
import Darwin
import Foundation

extension ProviderSyncEngine {
    func createBackup(codexHome: URL, sessionFiles: [URL], targetProvider: String) throws -> URL {
        let canonicalHome = canonicalProviderHome(codexHome)
        let root = backupRootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupName = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let backup = root.appendingPathComponent(backupName, isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        try copyIfExists(canonicalHome.appendingPathComponent("config.toml"), to: backup.appendingPathComponent("config.toml.before"))
        try backupSQLiteDatabase(
            source: canonicalHome.appendingPathComponent("state_5.sqlite"),
            destination: backup.appendingPathComponent("state_5.sqlite.before")
        )
        try copyIfExists(canonicalHome.appendingPathComponent("session_index.jsonl"), to: backup.appendingPathComponent("session_index.jsonl.before"))
        try copyIfExists(canonicalHome.appendingPathComponent(".codex-global-state.json"), to: backup.appendingPathComponent("codex-global-state.json.before"))
        try copyIfExists(canonicalHome.appendingPathComponent(".codex-global-state.json.bak"), to: backup.appendingPathComponent("codex-global-state.json.bak.before"))
        let sessionMembers = try createSessionTar(
            files: sessionFiles,
            relativeTo: canonicalHome,
            destination: backup.appendingPathComponent("session-jsonl.before.tar")
        )

        let manifest: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "codex_home": canonicalHome.path,
            "canonical_codex_home": canonicalHome.path,
            "target_provider": targetProvider,
            "session_file_count": sessionMembers.count,
            "session_members": sessionMembers.map { member in
                ["path": member.path, "sha256": member.sha256]
            }
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

    private func createSessionTar(
        files: [URL],
        relativeTo codexHome: URL,
        destination: URL
    ) throws -> [ProviderSyncManifestSessionMember] {
        let canonicalHome = canonicalBackupHome(codexHome)
        var seenIdentities = Set<ProviderSyncFileIdentity>()
        var seenPaths = Set<String>()
        let candidates = try files.map { file -> ProviderSyncArchiveSource in
            let source = file.standardizedFileURL
            let identity = try regularFileIdentityNoFollow(source, requireSingleLink: true)
            let resolvedFile = canonicalArchiveURL(source)
            guard isURL(resolvedFile, containedBy: canonicalHome) else {
                throw backupArchiveError("会话文件不在当前 Codex Home 内：\(file.path)")
            }
            let relativePath = String(resolvedFile.path.dropFirst(canonicalHome.path.count + 1))
            guard isScopedSessionPath(relativePath) else {
                throw backupArchiveError("会话文件路径不在允许范围内：\(relativePath)")
            }
            guard seenIdentities.insert(identity).inserted,
                  seenPaths.insert(relativePath).inserted else {
                throw backupArchiveError("会话文件 canonical 身份或目标重复：\(relativePath)")
            }
            return ProviderSyncArchiveSource(
                source: source,
                relativePath: relativePath,
                identity: identity
            )
        }.sorted { $0.relativePath < $1.relativePath }

        try sessionTarWillRun?()
        let stageRoot = destination.deletingLastPathComponent()
            .appendingPathComponent(".provider-backup-stage-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(at: stageRoot)
        defer { try? fileManager.removeItem(at: stageRoot) }

        var sessionMembers: [ProviderSyncManifestSessionMember] = []
        for candidate in candidates {
            let staged = stageRoot.appendingPathComponent(candidate.relativePath)
            try fileManager.createDirectory(
                at: staged.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try copyRegularFileNoFollow(
                from: candidate.source,
                to: staged,
                expectedIdentity: candidate.identity,
                requireSingleLink: true
            )
            _ = try regularFileIdentityNoFollow(staged, requireSingleLink: true)
            sessionMembers.append(ProviderSyncManifestSessionMember(
                path: candidate.relativePath,
                sha256: try sha256Hex(of: staged)
            ))
        }

        let memberPaths = candidates.map(\.relativePath)
        try sessionTarStageWillRun?(stageRoot)
        try runTar(arguments: ["-C", stageRoot.path, "-cf", destination.path]
            + (memberPaths.isEmpty ? ["-T", "/dev/null"] : memberPaths))
        try sessionTarDidRun?(destination)

        let validationManifest = ProviderSyncBackupManifest(
            rawCodexHome: canonicalHome.path,
            canonicalCodexHome: canonicalHome.path,
            sessionFileCount: sessionMembers.count,
            sessionMembers: sessionMembers
        )
        let validated = try stageValidatedSessionArchive(
            destination,
            workspaceParent: destination.deletingLastPathComponent(),
            canonicalHome: canonicalHome,
            manifest: validationManifest,
            invokeListHook: false
        )
        defer { try? fileManager.removeItem(at: validated.cleanupRoot) }
        return sessionMembers
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
        guard let manifest = try? validatedBackupManifest(backup) else { return false }
        return manifestCanonicalHome(manifest) == canonicalBackupHome(codexHome).path
    }

    func restoreBackup<T>(
        _ backup: URL,
        codexHome: URL,
        afterRestore: () throws -> T
    ) throws -> T {
        guard fileManager.fileExists(atPath: backup.appendingPathComponent("manifest.json").path) else {
            throw NSError(domain: "CodexTokenBar", code: 400, userInfo: [NSLocalizedDescriptionKey: "备份不属于当前 Codex Home，已拒绝回滚"])
        }
        let manifest = try validatedBackupManifest(backup)
        let canonicalHome = canonicalBackupHome(codexHome)
        guard manifestCanonicalHome(manifest) == canonicalHome.path else {
            throw NSError(domain: "CodexTokenBar", code: 400, userInfo: [NSLocalizedDescriptionKey: "备份不属于当前 Codex Home，已拒绝回滚"])
        }

        let stagedArchive = try stageSessionArchiveIfPresent(
            backup.appendingPathComponent("session-jsonl.before.tar"),
            backup: backup,
            canonicalHome: canonicalHome,
            manifest: manifest
        )
        defer {
            if let stagedArchive {
                try? fileManager.removeItem(at: stagedArchive.cleanupRoot)
            }
        }

        let transaction = try makeRestoreTransaction(
            backup: backup,
            canonicalHome: canonicalHome,
            stagedArchive: stagedArchive
        )
        do {
            try transaction.apply()
            try transaction.verifyAppliedState()
            let result = try afterRestore()
            transaction.commit()
            return result
        } catch let primaryError {
            do {
                try transaction.compensate()
            } catch let compensationError {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [
                        NSLocalizedDescriptionKey: "回滚事务失败，且目标补偿失败：\(primaryError.localizedDescription)；补偿错误：\(compensationError.localizedDescription)；恢复 journal：\(transaction.journalPath.path)"
                    ]
                )
            }
            throw primaryError
        }
    }

    private func validatedBackupManifest(_ backup: URL) throws -> ProviderSyncBackupManifest {
        let manifestURL = backup.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCodexHome = object["codex_home"] as? String,
              rawCodexHome.hasPrefix("/"),
              let sessionFileCount = object["session_file_count"] as? Int,
              sessionFileCount >= 0 else {
            throw backupArchiveError("manifest 无效或缺少必要字段")
        }

        var manifestMembers: [ProviderSyncManifestSessionMember]?
        if object.keys.contains("session_members") {
            guard let rawMembers = object["session_members"] as? [[String: Any]] else {
                throw backupArchiveError("manifest session_members 格式无效")
            }
            var seenPaths = Set<String>()
            manifestMembers = try rawMembers.map { rawMember in
                guard let path = rawMember["path"] as? String,
                      let sha256 = rawMember["sha256"] as? String,
                      isScopedSessionPath(path),
                      !path.contains("\\"),
                      sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      seenPaths.insert(path).inserted else {
                    throw backupArchiveError("manifest session_members 含无效或重复成员")
                }
                return ProviderSyncManifestSessionMember(path: path, sha256: sha256)
            }
            guard manifestMembers?.count == sessionFileCount else {
                throw backupArchiveError("manifest session_members 与 session_file_count 不一致")
            }
        }
        let canonicalCodexHome: String?
        if object.keys.contains("canonical_codex_home") {
            guard let value = object["canonical_codex_home"] as? String,
                  value.hasPrefix("/"),
                  URL(fileURLWithPath: value).standardizedFileURL.path == value else {
                throw backupArchiveError("manifest canonical_codex_home 无效")
            }
            canonicalCodexHome = value
        } else {
            canonicalCodexHome = nil
        }
        return ProviderSyncBackupManifest(
            rawCodexHome: rawCodexHome,
            canonicalCodexHome: canonicalCodexHome,
            sessionFileCount: sessionFileCount,
            sessionMembers: manifestMembers
        )
    }

    private func manifestCanonicalHome(_ manifest: ProviderSyncBackupManifest) -> String {
        manifest.canonicalCodexHome
            ?? canonicalBackupHome(URL(fileURLWithPath: manifest.rawCodexHome)).path
    }

    private func makeRestoreTransaction(
        backup: URL,
        canonicalHome: URL,
        stagedArchive: ProviderSyncStagedSessionArchive?
    ) throws -> ProviderSyncRestoreTransaction {
        var specifications: [ProviderSyncRestoreSpecification] = []
        func appendBackedUpFile(_ sourceName: String, destinationName: String, removeIfMissing: Bool) {
            let source = backup.appendingPathComponent(sourceName)
            if fileManager.fileExists(atPath: source.path) {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: source,
                    destination: canonicalHome.appendingPathComponent(destinationName)
                ))
            } else if removeIfMissing {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: nil,
                    destination: canonicalHome.appendingPathComponent(destinationName)
                ))
            }
        }

        appendBackedUpFile("config.toml.before", destinationName: "config.toml", removeIfMissing: false)
        let sqliteBackup = backup.appendingPathComponent("state_5.sqlite.before")
        if fileManager.fileExists(atPath: sqliteBackup.path) {
            specifications.append(ProviderSyncRestoreSpecification(
                source: sqliteBackup,
                destination: canonicalHome.appendingPathComponent("state_5.sqlite")
            ))
            specifications.append(ProviderSyncRestoreSpecification(
                source: nil,
                destination: canonicalHome.appendingPathComponent("state_5.sqlite-wal")
            ))
            specifications.append(ProviderSyncRestoreSpecification(
                source: nil,
                destination: canonicalHome.appendingPathComponent("state_5.sqlite-shm")
            ))
        }
        appendBackedUpFile("session_index.jsonl.before", destinationName: "session_index.jsonl", removeIfMissing: true)
        appendBackedUpFile("codex-global-state.json.before", destinationName: ".codex-global-state.json", removeIfMissing: false)
        appendBackedUpFile("codex-global-state.json.bak.before", destinationName: ".codex-global-state.json.bak", removeIfMissing: false)

        if let stagedArchive {
            for member in stagedArchive.members {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: stagedArchive.root.appendingPathComponent(member.archivePath),
                    destination: canonicalHome.appendingPathComponent(member.relativePath)
                ))
            }
        }

        return try ProviderSyncRestoreTransaction(
            fileManager: fileManager,
            canonicalHome: canonicalHome,
            specifications: specifications,
            willApply: restoreWillApply,
            willCompensate: restoreWillCompensate
        )
    }

    private func stageSessionArchiveIfPresent(
        _ archive: URL,
        backup: URL,
        canonicalHome: URL,
        manifest: ProviderSyncBackupManifest
    ) throws -> ProviderSyncStagedSessionArchive? {
        guard providerSyncPathExistsNoFollow(archive.path) else {
            if manifest.sessionFileCount > 0 {
                throw backupArchiveError("备份声明包含会话文件，但会话归档缺失")
            }
            return nil
        }

        return try stageValidatedSessionArchive(
            archive,
            workspaceParent: backup.deletingLastPathComponent(),
            canonicalHome: canonicalHome,
            manifest: manifest,
            invokeListHook: true
        )
    }

    private func stageValidatedSessionArchive(
        _ archive: URL,
        workspaceParent: URL,
        canonicalHome: URL,
        manifest: ProviderSyncBackupManifest,
        invokeListHook: Bool
    ) throws -> ProviderSyncStagedSessionArchive {
        let workspaceRoot = workspaceParent
            .appendingPathComponent(".provider-archive-snapshot-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(at: workspaceRoot)
        let canonicalWorkspaceRoot = canonicalArchiveURL(workspaceRoot)
        let snapshot = canonicalWorkspaceRoot.appendingPathComponent("archive.tar")
        do {
            try copyRegularFileNoFollow(
                from: archive,
                to: snapshot,
                expectedIdentity: nil,
                requireSingleLink: false
            )
            _ = try regularFileIdentityNoFollow(snapshot, requireSingleLink: true)

            let members = try validatedSessionArchiveMembers(
                snapshot,
                canonicalHome: canonicalHome,
                manifest: manifest
            )
            if invokeListHook {
                try sessionArchiveDidList?()
            }
            guard members.count == manifest.sessionFileCount else {
                throw backupArchiveError("归档成员数量与 manifest session_file_count 不一致")
            }
            if let exactMembers = manifest.sessionMembers {
                let archivedPaths = Set(members.map(\.relativePath))
                let manifestPaths = Set(exactMembers.map(\.path))
                guard archivedPaths == manifestPaths,
                      members.allSatisfy({ $0.archivePath == $0.relativePath }) else {
                    throw backupArchiveError("归档成员集合与 manifest session_members 不一致")
                }
            }
            let stagingRoot = canonicalWorkspaceRoot.appendingPathComponent("contents", isDirectory: true)
            try createPrivateDirectory(at: stagingRoot)
            try runTar(arguments: [
                "-C", stagingRoot.path,
                "-xf", snapshot.path,
                "--no-same-owner",
                "--no-same-permissions"
            ])
            try validateStagedArchive(
                stagingRoot,
                members: members,
                manifestMembers: manifest.sessionMembers
            )
            return ProviderSyncStagedSessionArchive(
                cleanupRoot: canonicalWorkspaceRoot,
                root: stagingRoot,
                members: members
            )
        } catch {
            try? fileManager.removeItem(at: canonicalWorkspaceRoot)
            throw error
        }
    }

    private func validatedSessionArchiveMembers(
        _ archive: URL,
        canonicalHome: URL,
        manifest: ProviderSyncBackupManifest
    ) throws -> [ProviderSyncSessionArchiveMember] {
        let memberLines = try validatedTarListingLines(arguments: ["-tf", archive.path])
        let verboseLines = try validatedTarListingLines(arguments: ["-tvf", archive.path])
        guard memberLines.count == verboseLines.count else {
            throw backupArchiveError("归档成员清单无法可靠解析")
        }

        var seenArchivePaths = Set<String>()
        var seenRelativePaths = Set<String>()
        var seenCanonicalDestinations = Set<String>()
        let rawHomeWithoutLeadingSlash = String(manifest.rawCodexHome.dropFirst())
        let legacyHomePrefix = rawHomeWithoutLeadingSlash.hasSuffix("/")
            ? rawHomeWithoutLeadingSlash
            : rawHomeWithoutLeadingSlash + "/"
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
            guard isURL(canonicalDestination, containedBy: canonicalHome),
                  seenCanonicalDestinations.insert(canonicalDestination.path).inserted else {
                throw backupArchiveError("归档成员目标解析到 Codex Home 之外或 canonical 目标重复：\(archivePath)")
            }
            return ProviderSyncSessionArchiveMember(
                archivePath: archivePath,
                relativePath: relativePath
            )
        }
    }

    private func validateStagedArchive(
        _ stagingRoot: URL,
        members: [ProviderSyncSessionArchiveMember],
        manifestMembers: [ProviderSyncManifestSessionMember]?
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
        if let manifestMembers {
            let expectedDigests = Dictionary(uniqueKeysWithValues: manifestMembers.map { ($0.path, $0.sha256) })
            for member in members {
                let stagedFile = stagingRoot.appendingPathComponent(member.archivePath)
                guard try sha256Hex(of: stagedFile) == expectedDigests[member.relativePath] else {
                    throw backupArchiveError("归档成员内容摘要与 manifest 不一致：\(member.relativePath)")
                }
            }
        }
    }

    private func validatedTarListingLines(arguments: [String]) throws -> [String] {
        let outputData = try tarOutput(arguments: arguments)
        guard outputData.allSatisfy({ byte in
            byte == 0x0A || (byte >= 0x20 && byte != 0x5C && byte != 0x7F)
        }), let output = String(data: outputData, encoding: .utf8) else {
            throw backupArchiveError("归档成员清单包含反斜杠转义、控制字节或无效 UTF-8")
        }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.allSatisfy({ !$0.isEmpty }) else {
            throw backupArchiveError("归档成员清单包含空行或换行歧义")
        }
        return lines
    }

    private func tarOutput(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        let diagnosticsURL = fileManager.temporaryDirectory
            .appendingPathComponent("provider-tar-diagnostics-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: diagnosticsURL.path, contents: nil),
              let diagnostics = try? FileHandle(forWritingTo: diagnosticsURL) else {
            throw backupArchiveError("无法创建 tar 诊断文件")
        }
        defer {
            try? diagnostics.close()
            try? fileManager.removeItem(at: diagnosticsURL)
        }
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try diagnostics.close()
        let diagnosticData = (try? Data(contentsOf: diagnosticsURL)) ?? Data()
        guard process.terminationStatus == 0, diagnosticData.isEmpty else {
            let message = String(data: diagnosticData, encoding: .utf8) ?? "tar failed"
            throw backupArchiveError(message)
        }
        return outputData
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
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isURL(_ candidate: URL, containedBy root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }

    private func isLexicallySafeArchivePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let hasOnlyUnambiguousScalars = path.unicodeScalars.allSatisfy { scalar in
            guard scalar.value != 0x5C else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
        return hasOnlyUnambiguousScalars
            && !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isScopedSessionPath(_ path: String) -> Bool {
        guard isLexicallySafeArchivePath(path), path.hasSuffix(".jsonl") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let root = components.first else { return false }
        return components.count >= 2 && (root == "sessions" || root == "archived_sessions")
    }

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func regularFileIdentityNoFollow(
        _ url: URL,
        requireSingleLink: Bool
    ) throws -> ProviderSyncFileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw backupArchiveError("无法无跟随读取文件：\(url.path)（\(providerSyncPOSIXMessage())）")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw backupArchiveError("文件不是无符号链接的常规文件：\(url.path)")
        }
        if requireSingleLink, metadata.st_nlink != 1 {
            throw backupArchiveError("文件存在 hardlink，已拒绝备份：\(url.path)")
        }
        return ProviderSyncFileIdentity(metadata)
    }

    private func copyRegularFileNoFollow(
        from source: URL,
        to destination: URL,
        expectedIdentity: ProviderSyncFileIdentity?,
        requireSingleLink: Bool
    ) throws {
        let identityBeforeOpen = try regularFileIdentityNoFollow(
            source,
            requireSingleLink: requireSingleLink
        )
        if let expectedIdentity, identityBeforeOpen != expectedIdentity {
            throw backupArchiveError("文件在检查与复制之间发生身份变化：\(source.path)")
        }
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else {
            throw backupArchiveError("无法无跟随打开文件：\(source.path)（\(providerSyncPOSIXMessage())）")
        }
        defer { Darwin.close(sourceDescriptor) }

        var metadata = stat()
        guard fstat(sourceDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw backupArchiveError("打开后的源不是常规文件：\(source.path)")
        }
        if requireSingleLink, metadata.st_nlink != 1 {
            throw backupArchiveError("打开后的源存在 hardlink，已拒绝备份：\(source.path)")
        }
        let actualIdentity = ProviderSyncFileIdentity(metadata)
        if let expectedIdentity, actualIdentity != expectedIdentity {
            throw backupArchiveError("文件在检查与复制之间发生身份变化：\(source.path)")
        }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw backupArchiveError("无法创建私有 staging 文件：\(destination.path)（\(providerSyncPOSIXMessage())）")
        }
        defer { Darwin.close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw backupArchiveError("读取源文件失败：\(source.path)（\(providerSyncPOSIXMessage())）")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        count - offset
                    )
                }
                guard written > 0 else {
                    throw backupArchiveError("写入 staging 文件失败：\(destination.path)（\(providerSyncPOSIXMessage())）")
                }
                offset += written
            }
        }
    }

    private func backupArchiveError(_ message: String) -> NSError {
        NSError(
            domain: "CodexTokenBar",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "会话归档成员校验失败：\(message)"]
        )
    }

    private func sha256Hex(of file: URL) throws -> String {
        providerSyncSHA256Hex(try Data(contentsOf: file))
    }

}

private struct ProviderSyncSessionArchiveMember {
    let archivePath: String
    let relativePath: String
}

private struct ProviderSyncArchiveSource {
    let source: URL
    let relativePath: String
    let identity: ProviderSyncFileIdentity
}

private struct ProviderSyncFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(UInt32(bitPattern: metadata.st_dev))
        inode = UInt64(metadata.st_ino)
    }
}

private struct ProviderSyncStagedSessionArchive {
    let cleanupRoot: URL
    let root: URL
    let members: [ProviderSyncSessionArchiveMember]
}

private struct ProviderSyncBackupManifest {
    let rawCodexHome: String
    let canonicalCodexHome: String?
    let sessionFileCount: Int
    let sessionMembers: [ProviderSyncManifestSessionMember]?
}

private struct ProviderSyncManifestSessionMember {
    let path: String
    let sha256: String
}

private struct ProviderSyncRestoreSpecification {
    let source: URL?
    let destination: URL
}

private struct ProviderSyncRestoreOperation {
    let replacement: URL?
    let original: URL
    let destination: URL
    let expectedDigest: String?
    var destinationExisted = false
    var originalDigest: String?
    var journaled = false
    var applied = false
    var compensated = false
}

private final class ProviderSyncRestoreTransaction {
    private let fileManager: FileManager
    private let canonicalHome: URL
    private let transactionRoot: URL
    private let willApply: ((Int, URL) throws -> Void)?
    private let willCompensate: ((Int, URL) throws -> Void)?
    private var operations: [ProviderSyncRestoreOperation]
    private var journaledIndices: [Int] = []
    private var createdDirectories: [URL] = []
    private var finished = false

    var journalPath: URL { transactionRoot }

    init(
        fileManager: FileManager,
        canonicalHome: URL,
        specifications: [ProviderSyncRestoreSpecification],
        willApply: ((Int, URL) throws -> Void)?,
        willCompensate: ((Int, URL) throws -> Void)?
    ) throws {
        let root = canonicalHome.appendingPathComponent(
            ".provider-restore-transaction-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        var prepared: [ProviderSyncRestoreOperation] = []
        var seenDestinations = Set<String>()
        do {
            for specification in specifications {
                let canonicalDestination = specification.destination
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard canonicalDestination.path == canonicalHome.path
                        || canonicalDestination.path.hasPrefix(canonicalHome.path + "/"),
                      seenDestinations.insert(canonicalDestination.path).inserted else {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "回滚 canonical 目标越界或重复：\(specification.destination.path)"]
                    )
                }
            }
            for (index, specification) in specifications.enumerated() {
                let original = root
                    .appendingPathComponent("originals", isDirectory: true)
                    .appendingPathComponent(String(index))
                var replacement: URL?
                var expectedDigest: String?
                if let source = specification.source {
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw NSError(
                            domain: "CodexTokenBar",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "回滚源不是常规文件：\(source.path)"]
                        )
                    }
                    let staged = root
                        .appendingPathComponent("replacements", isDirectory: true)
                        .appendingPathComponent(String(index))
                    try fileManager.createDirectory(
                        at: staged.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: source, to: staged)
                    replacement = staged
                    expectedDigest = providerSyncSHA256Hex(try Data(contentsOf: staged))
                }
                prepared.append(ProviderSyncRestoreOperation(
                    replacement: replacement,
                    original: original,
                    destination: specification.destination,
                    expectedDigest: expectedDigest
                ))
            }
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
        self.fileManager = fileManager
        self.canonicalHome = canonicalHome
        self.transactionRoot = root
        self.willApply = willApply
        self.willCompensate = willCompensate
        self.operations = prepared
    }

    func apply() throws {
        for index in operations.indices {
            do {
                try ensureDestinationParent(for: operations[index].destination)
                let destinationExisted = providerSyncPathExistsNoFollow(operations[index].destination.path)
                operations[index].destinationExisted = destinationExisted
                if destinationExisted {
                    let values = try operations[index].destination.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw NSError(
                            domain: "CodexTokenBar",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "回滚目标不是常规文件：\(operations[index].destination.path)"]
                        )
                    }
                    operations[index].originalDigest = providerSyncSHA256Hex(
                        try Data(contentsOf: operations[index].destination)
                    )
                    try fileManager.createDirectory(
                        at: operations[index].original.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(
                        at: operations[index].destination,
                        to: operations[index].original
                    )
                }
                operations[index].journaled = true
                journaledIndices.append(index)
                try willApply?(index, operations[index].destination)
                if let replacement = operations[index].replacement {
                    try fileManager.moveItem(at: replacement, to: operations[index].destination)
                }
                operations[index].applied = true
            } catch {
                if operations[index].journaled {
                    do {
                        try compensateOperation(index)
                        try verifyCompensatedState(index)
                        operations[index].compensated = true
                    } catch {
                        // General compensation retries this journaled operation.
                    }
                }
                throw error
            }
        }
    }

    func verifyAppliedState() throws {
        for operation in operations where operation.applied {
            if let expectedDigest = operation.expectedDigest {
                guard fileManager.fileExists(atPath: operation.destination.path),
                      providerSyncSHA256Hex(try Data(contentsOf: operation.destination)) == expectedDigest else {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "回滚目标内容校验失败：\(operation.destination.path)"]
                    )
                }
            } else if fileManager.fileExists(atPath: operation.destination.path) {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "回滚目标应保持不存在：\(operation.destination.path)"]
                )
            }
        }
    }

    func compensate() throws {
        guard !finished else { return }
        var failures: [String] = []
        for index in journaledIndices.reversed() where !operations[index].compensated {
            do {
                try compensateOperation(index)
                try verifyCompensatedState(index)
                operations[index].compensated = true
            } catch {
                failures.append("\(operations[index].destination.path)：\(error.localizedDescription)")
            }
        }
        for index in journaledIndices where operations[index].compensated {
            do {
                try verifyCompensatedState(index)
            } catch {
                operations[index].compensated = false
                failures.append("\(operations[index].destination.path)：\(error.localizedDescription)")
            }
        }
        guard failures.isEmpty,
              journaledIndices.allSatisfy({ operations[$0].compensated }) else {
            throw NSError(
                domain: "CodexTokenBar",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "补偿未完整恢复，已保留 journal：\(transactionRoot.path)；\(failures.joined(separator: "；"))"
                ]
            )
        }
        finished = true
        try fileManager.removeItem(at: transactionRoot)
        removeCreatedDirectoriesIfEmpty()
    }

    func commit() {
        guard !finished else { return }
        finished = true
        try? fileManager.removeItem(at: transactionRoot)
    }

    private func compensateOperation(_ index: Int) throws {
        let operation = operations[index]
        try willCompensate?(index, operation.destination)
        if providerSyncPathExistsNoFollow(operation.destination.path) {
            let discarded = transactionRoot
                .appendingPathComponent("discarded", isDirectory: true)
                .appendingPathComponent("\(index)-\(UUID().uuidString)")
            try fileManager.createDirectory(
                at: discarded.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: operation.destination, to: discarded)
        }
        if operation.destinationExisted {
            guard providerSyncPathExistsNoFollow(operation.original.path) else {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "journal 原始文件缺失：\(operation.original.path)"]
                )
            }
            try ensureDestinationParent(for: operation.destination)
            try fileManager.moveItem(at: operation.original, to: operation.destination)
        }
    }

    private func verifyCompensatedState(_ index: Int) throws {
        let operation = operations[index]
        if operation.destinationExisted {
            guard let originalDigest = operation.originalDigest,
                  providerSyncPathExistsNoFollow(operation.destination.path),
                  providerSyncSHA256Hex(try Data(contentsOf: operation.destination)) == originalDigest else {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "补偿后原始内容校验失败：\(operation.destination.path)"]
                )
            }
        } else if providerSyncPathExistsNoFollow(operation.destination.path) {
            throw NSError(
                domain: "CodexTokenBar",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "补偿后目标应保持不存在：\(operation.destination.path)"]
            )
        }
    }

    private func ensureDestinationParent(for destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedParent.path == canonicalHome.path
                || resolvedParent.path.hasPrefix(canonicalHome.path + "/") else {
            throw NSError(
                domain: "CodexTokenBar",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "回滚目标父目录解析到 Codex Home 之外：\(parent.path)"]
            )
        }
        var ancestor = parent
        while ancestor.path != canonicalHome.path {
            if providerSyncPathIsSymlink(ancestor.path) {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "回滚目标含符号链接父目录：\(ancestor.path)"]
                )
            }
            ancestor.deleteLastPathComponent()
        }
        var missing: [URL] = []
        var cursor = parent
        while cursor.path != canonicalHome.path,
              !fileManager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        for directory in missing.reversed() {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectories.append(directory)
        }
    }

    private func removeCreatedDirectoriesIfEmpty() {
        for directory in createdDirectories.reversed() {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }
}

private func providerSyncSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func providerSyncPathExistsNoFollow(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
}

private func providerSyncPathIsSymlink(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
}

private func providerSyncPOSIXMessage() -> String {
    String(cString: strerror(errno))
}
