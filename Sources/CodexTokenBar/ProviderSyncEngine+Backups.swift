import Darwin
import Foundation

extension ProviderSyncEngine {
    func createBackup(codexHome: URL, sessionFiles: [URL], targetProvider: String) throws -> URL {
        let canonicalHome = canonicalProviderHome(codexHome)
        guard let expectedHomeIdentity = CodexHomeIdentity.read(
            at: canonicalHome,
            fileManager: fileManager
        ) else {
            throw providerSyncDescriptorError(
                "无法读取 Codex Home expected identity：\(canonicalHome.path)"
            )
        }
        return try withMutationLease(
            codexHome: canonicalHome,
            expectedHomeIdentity: expectedHomeIdentity
        ) { pinnedHome, homeDirectory in
            try createBackupForMutation(
                codexHome: pinnedHome,
                homeDirectory: homeDirectory,
                sessionFiles: sessionFiles,
                targetProvider: targetProvider
            ).url
        }
    }

    func createBackupForMutation(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        sessionFiles: [URL],
        targetProvider: String
    ) throws -> ProviderSyncCreatedBackup {
        let canonicalHome = canonicalProviderHome(codexHome)
        let root = backupRootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupName = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let backup = root.appendingPathComponent(backupName, isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try backupWillReadHome?()
        try homeDirectory.verifyRootPathIdentity()

        try copyHomeFileIfExists(
            homeDirectory: homeDirectory,
            relativePath: "config.toml",
            destination: backup.appendingPathComponent("config.toml.before")
        )
        try backupSQLiteDatabase(
            homeDirectory: homeDirectory,
            destination: backup.appendingPathComponent("state_5.sqlite.before")
        )
        try copyHomeFileIfExists(
            homeDirectory: homeDirectory,
            relativePath: "session_index.jsonl",
            destination: backup.appendingPathComponent("session_index.jsonl.before")
        )
        try copyHomeFileIfExists(
            homeDirectory: homeDirectory,
            relativePath: ".codex-global-state.json",
            destination: backup.appendingPathComponent("codex-global-state.json.before")
        )
        try copyHomeFileIfExists(
            homeDirectory: homeDirectory,
            relativePath: ".codex-global-state.json.bak",
            destination: backup.appendingPathComponent("codex-global-state.json.bak.before")
        )
        let sessionBackup = try createSessionTar(
            files: sessionFiles,
            relativeTo: canonicalHome,
            homeDirectory: homeDirectory,
            destination: backup.appendingPathComponent("session-jsonl.before.tar")
        )
        try homeDirectory.verifyRootPathIdentity()

        let manifest: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "codex_home": canonicalHome.path,
            "canonical_codex_home": canonicalHome.path,
            "target_provider": targetProvider,
            "session_file_count": sessionBackup.members.count,
            "session_members": sessionBackup.members.map { member in
                ["path": member.path, "sha256": member.sha256]
            }
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: backup.appendingPathComponent("manifest.json"), options: [.atomic])
        return ProviderSyncCreatedBackup(
            url: backup,
            sessionBindings: sessionBackup.bindings
        )
    }

    func copyHomeFileIfExists(
        homeDirectory: ProviderSyncHomeDirectory,
        relativePath: String,
        destination: URL
    ) throws {
        guard let snapshot = try homeDirectory.readOptionalRegularFile(
            relativePath: relativePath,
            requireSingleLink: true
        ) else {
            return
        }
        try snapshot.data.write(to: destination, options: [.atomic])
        try homeDirectory.verifyRootPathIdentity()
    }

    func backupSQLiteDatabase(
        homeDirectory: ProviderSyncHomeDirectory,
        destination: URL
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        _ = try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, bound in
            try homeDirectory.verifyBoundFile(bound)
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            _ = try executeBoundUpdate(
                database: database,
                sql: "VACUUM main INTO ?;",
                values: [destination.path]
            )
            try homeDirectory.verifyBoundFile(bound)
        }
    }

    private func createSessionTar(
        files: [URL],
        relativeTo codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        destination: URL
    ) throws -> ProviderSyncSessionBackupResult {
        let canonicalHome = canonicalBackupHome(codexHome)
        var seenIdentities = Set<ProviderSyncFileIdentity>()
        var seenPaths = Set<String>()
        let candidates = try files.map { file -> ProviderSyncArchiveSource in
            let source = file.standardizedFileURL
            guard source.path.hasPrefix(canonicalHome.path + "/") else {
                throw backupArchiveError("会话文件不在当前 Codex Home 内：\(file.path)")
            }
            let relativePath = String(source.path.dropFirst(canonicalHome.path.count + 1))
            guard isScopedSessionPath(relativePath) else {
                throw backupArchiveError("会话文件路径不在允许范围内：\(relativePath)")
            }
            let pinned = try homeDirectory.pinFile(relativePath: relativePath, createParents: false)
            guard let metadata = try homeDirectory.entryMetadata(pinned),
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1 else {
                throw backupArchiveError("会话文件不是独立常规文件：\(relativePath)")
            }
            let identity = ProviderSyncFileIdentity(metadata)
            guard seenIdentities.insert(identity).inserted,
                  seenPaths.insert(relativePath).inserted else {
                throw backupArchiveError("会话文件 canonical 身份或目标重复：\(relativePath)")
            }
            return ProviderSyncArchiveSource(
                pinned: pinned,
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
            let snapshot = try homeDirectory.readRegularFile(
                candidate.pinned,
                expectedIdentity: candidate.identity,
                requireSingleLink: true
            )
            try snapshot.data.write(to: staged, options: [.atomic])
            _ = try regularFileIdentityNoFollow(staged, requireSingleLink: true)
            sessionMembers.append(ProviderSyncManifestSessionMember(
                path: candidate.relativePath,
                sha256: providerSyncSHA256Hex(snapshot.data)
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
        let digests = Dictionary(uniqueKeysWithValues: sessionMembers.map { ($0.path, $0.sha256) })
        let bindings = try candidates.map { candidate in
            guard let digest = digests[candidate.relativePath] else {
                throw backupArchiveError("staged session digest 缺失：\(candidate.relativePath)")
            }
            return ProviderSyncSessionMutationBinding(
                relativePath: candidate.relativePath,
                identity: candidate.identity,
                sha256: digest
            )
        }
        return ProviderSyncSessionBackupResult(
            members: sessionMembers,
            bindings: bindings
        )
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
        homeDirectory: ProviderSyncHomeDirectory,
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
            homeDirectory: homeDirectory,
            stagedArchive: stagedArchive
        )
        do {
            try transaction.apply()
            try transaction.verifyAppliedState()
            let result = try afterRestore()
            try transaction.verifyAppliedState(invokeHooks: false)
            try transaction.commit()
            return result
        } catch let commitError as ProviderSyncRestoreCommitError {
            throw commitError
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
        homeDirectory: ProviderSyncHomeDirectory,
        stagedArchive: ProviderSyncStagedSessionArchive?
    ) throws -> ProviderSyncRestoreTransaction {
        var specifications: [ProviderSyncRestoreSpecification] = []
        func appendBackedUpFile(_ sourceName: String, destinationName: String, removeIfMissing: Bool) {
            let source = backup.appendingPathComponent(sourceName)
            if fileManager.fileExists(atPath: source.path) {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: source,
                    relativeDestination: destinationName
                ))
            } else if removeIfMissing {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: nil,
                    relativeDestination: destinationName
                ))
            }
        }

        appendBackedUpFile("config.toml.before", destinationName: "config.toml", removeIfMissing: false)
        let sqliteBackup = backup.appendingPathComponent("state_5.sqlite.before")
        if fileManager.fileExists(atPath: sqliteBackup.path) {
            specifications.append(ProviderSyncRestoreSpecification(
                source: sqliteBackup,
                relativeDestination: "state_5.sqlite"
            ))
            specifications.append(ProviderSyncRestoreSpecification(
                source: nil,
                relativeDestination: "state_5.sqlite-wal"
            ))
            specifications.append(ProviderSyncRestoreSpecification(
                source: nil,
                relativeDestination: "state_5.sqlite-shm"
            ))
        }
        appendBackedUpFile("session_index.jsonl.before", destinationName: "session_index.jsonl", removeIfMissing: true)
        appendBackedUpFile("codex-global-state.json.before", destinationName: ".codex-global-state.json", removeIfMissing: false)
        appendBackedUpFile("codex-global-state.json.bak.before", destinationName: ".codex-global-state.json.bak", removeIfMissing: false)

        if let stagedArchive {
            for member in stagedArchive.members {
                specifications.append(ProviderSyncRestoreSpecification(
                    source: stagedArchive.root.appendingPathComponent(member.archivePath),
                    relativeDestination: member.relativePath
                ))
            }
        }

        return try ProviderSyncRestoreTransaction(
            fileManager: fileManager,
            canonicalHome: canonicalHome,
            homeDirectory: homeDirectory,
            specifications: specifications,
            willApply: restoreWillApply,
            destinationWillJournal: restoreDestinationWillJournal,
            willVerifyApplied: restoreWillVerifyApplied,
            willCompensate: restoreWillCompensate,
            willVerifyCompensated: restoreWillVerifyCompensated,
            journalWillOpen: restoreJournalWillOpen,
            journalDidRead: restoreJournalDidRead,
            cleanupWillBegin: restoreCleanupWillBegin,
            cleanupDidRemoveEntry: restoreCleanupDidRemoveEntry,
            cleanupWillRemoveRoot: restoreCleanupWillRemoveRoot
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
        try regularFileWillOpen?(source)
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
        guard actualIdentity == identityBeforeOpen else {
            throw backupArchiveError("文件在 lstat 与 open 之间发生身份变化：\(source.path)")
        }
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
    let pinned: ProviderSyncPinnedFile
    let relativePath: String
    let identity: ProviderSyncFileIdentity
}

struct ProviderSyncSessionMutationBinding {
    let relativePath: String
    let identity: ProviderSyncFileIdentity
    let sha256: String
}

struct ProviderSyncCreatedBackup {
    let url: URL
    let sessionBindings: [ProviderSyncSessionMutationBinding]
}

private struct ProviderSyncSessionBackupResult {
    let members: [ProviderSyncManifestSessionMember]
    let bindings: [ProviderSyncSessionMutationBinding]
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
    let relativeDestination: String
}

private struct ProviderSyncRestoreOperation {
    let replacementName: String?
    let replacementIdentity: ProviderSyncFileIdentity?
    let originalName: String
    let destination: ProviderSyncPinnedFile
    let expectedDigest: String?
    var destinationExisted = false
    var originalDigest: String?
    var originalIdentity: ProviderSyncFileIdentity?
    var appliedIdentity: ProviderSyncFileIdentity?
    var compensatedIdentity: ProviderSyncFileIdentity?
    var placeholderIdentity: ProviderSyncFileIdentity?
    var placeholderCleanupName: String?
    var journaled = false
    var applied = false
    var compensated = false
}

private struct ProviderSyncDestinationIdentity: Hashable {
    let parent: ProviderSyncFileIdentity
    let name: String
}

private struct ProviderSyncRestoreCommitError: LocalizedError {
    let journalPath: URL
    let underlying: Error

    var errorDescription: String? {
        "restore 已验证，但 journal cleanup 未完成：\(underlying.localizedDescription)；保留 transaction：\(journalPath.path)"
    }
}

private final class ProviderSyncRestoreTransaction {
    private let homeDirectory: ProviderSyncHomeDirectory
    private let transactionName: String
    private let transactionRootURL: URL
    private let transaction: ProviderSyncOwnedFileDescriptor
    private let originals: ProviderSyncOwnedFileDescriptor
    private let replacements: ProviderSyncOwnedFileDescriptor
    private let discarded: ProviderSyncOwnedFileDescriptor
    private let recovery: ProviderSyncOwnedFileDescriptor
    private let willApply: ((Int, URL) throws -> Void)?
    private let destinationWillJournal: ((Int, URL) throws -> Void)?
    private let willVerifyApplied: ((Int, URL) throws -> Void)?
    private let willCompensate: ((Int, URL) throws -> Void)?
    private let willVerifyCompensated: ((Int, URL) throws -> Void)?
    private let journalWillOpen: ((Int, URL) throws -> Void)?
    private let journalDidRead: ((Int, URL) throws -> Void)?
    private let cleanupWillBegin: ((URL) throws -> Void)?
    private let cleanupDidRemoveEntry: ((URL) throws -> Void)?
    private let cleanupWillRemoveRoot: ((URL) throws -> Void)?
    private var lastKnownJournalPath: URL
    private var operations: [ProviderSyncRestoreOperation]
    private var journaledIndices: [Int] = []
    private var createdDirectories: [String] = []
    private var discardedNames: [String] = []
    private var recoveryNames: [String] = []
    private var preservationFailures: [String] = []
    private var cleanupDidBegin = false
    private var cleanupDidReportPartialRemoval = false
    private var cleanupContentsRemoved = false
    private var cleanupDirectoriesRemoved = false
    private var cleanupDescriptorsClosed = false
    private var cleanupDidRequestRootRemoval = false
    private var finished = false

    var journalPath: URL {
        if let current = providerSyncDescriptorPath(transaction.rawValue) {
            lastKnownJournalPath = current
        }
        return lastKnownJournalPath
    }

    init(
        fileManager: FileManager,
        canonicalHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        specifications: [ProviderSyncRestoreSpecification],
        willApply: ((Int, URL) throws -> Void)?,
        destinationWillJournal: ((Int, URL) throws -> Void)?,
        willVerifyApplied: ((Int, URL) throws -> Void)?,
        willCompensate: ((Int, URL) throws -> Void)?,
        willVerifyCompensated: ((Int, URL) throws -> Void)?,
        journalWillOpen: ((Int, URL) throws -> Void)?,
        journalDidRead: ((Int, URL) throws -> Void)?,
        cleanupWillBegin: ((URL) throws -> Void)?,
        cleanupDidRemoveEntry: ((URL) throws -> Void)?,
        cleanupWillRemoveRoot: ((URL) throws -> Void)?
    ) throws {
        _ = fileManager
        let transactionName = ".provider-restore-transaction-\(UUID().uuidString)"
        let rootURL = canonicalHome.appendingPathComponent(transactionName, isDirectory: true)
        let transaction = try providerSyncCreateDirectoryDescriptor(
            parent: homeDirectory.descriptor,
            name: transactionName
        )
        var originals: ProviderSyncOwnedFileDescriptor?
        var replacements: ProviderSyncOwnedFileDescriptor?
        var discarded: ProviderSyncOwnedFileDescriptor?
        var recovery: ProviderSyncOwnedFileDescriptor?
        var prepared: [ProviderSyncRestoreOperation] = []
        var seenDestinations = Set<ProviderSyncDestinationIdentity>()
        var createdDirectories: [String] = []
        do {
            originals = try providerSyncCreateDirectoryDescriptor(
                parent: transaction.rawValue,
                name: "originals"
            )
            replacements = try providerSyncCreateDirectoryDescriptor(
                parent: transaction.rawValue,
                name: "replacements"
            )
            discarded = try providerSyncCreateDirectoryDescriptor(
                parent: transaction.rawValue,
                name: "discarded"
            )
            recovery = try providerSyncCreateDirectoryDescriptor(
                parent: transaction.rawValue,
                name: "recovery"
            )
            guard originals != nil,
                  let replacementDirectory = replacements,
                  discarded != nil,
                  recovery != nil else {
                throw providerSyncDescriptorError("无法建立 restore transaction descriptor 目录")
            }

            for (index, specification) in specifications.enumerated() {
                let destination = try homeDirectory.pinFile(
                    relativePath: specification.relativeDestination,
                    createParents: true
                )
                createdDirectories.append(contentsOf: destination.createdDirectories)
                let destinationIdentity = ProviderSyncDestinationIdentity(
                    parent: destination.parentIdentity,
                    name: destination.name
                )
                guard seenDestinations.insert(destinationIdentity).inserted else {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "回滚 descriptor 目标重复：\(destination.displayURL.path)"]
                    )
                }
                let entryName = String(index)
                var replacementName: String?
                var replacementIdentity: ProviderSyncFileIdentity?
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
                    let data = try Data(contentsOf: source)
                    try providerSyncCreateRegularFile(
                        directory: replacementDirectory.rawValue,
                        name: entryName,
                        data: data
                    )
                    replacementName = entryName
                    replacementIdentity = try providerSyncEntryMetadata(
                        directory: replacementDirectory.rawValue,
                        name: entryName
                    ).map(ProviderSyncFileIdentity.init)
                    expectedDigest = providerSyncSHA256Hex(data)
                }
                prepared.append(ProviderSyncRestoreOperation(
                    replacementName: replacementName,
                    replacementIdentity: replacementIdentity,
                    originalName: entryName,
                    destination: destination,
                    expectedDigest: expectedDigest
                ))
            }
        } catch {
            Self.cleanupInitializationFailure(
                homeDirectory: homeDirectory,
                transactionName: transactionName,
                transaction: transaction,
                originals: originals,
                replacements: replacements,
                discarded: discarded,
                recovery: recovery,
                possibleEntryCount: specifications.count
            )
            for directory in Set(createdDirectories).sorted(by: { $0.count > $1.count }) {
                homeDirectory.removeCreatedDirectoryIfEmpty(relativePath: directory)
            }
            throw error
        }
        guard let openedOriginals = originals,
              let openedReplacements = replacements,
              let openedDiscarded = discarded,
              let openedRecovery = recovery else {
            Self.cleanupInitializationFailure(
                homeDirectory: homeDirectory,
                transactionName: transactionName,
                transaction: transaction,
                originals: originals,
                replacements: replacements,
                discarded: discarded,
                recovery: recovery,
                possibleEntryCount: specifications.count
            )
            for directory in Set(createdDirectories).sorted(by: { $0.count > $1.count }) {
                homeDirectory.removeCreatedDirectoryIfEmpty(relativePath: directory)
            }
            throw providerSyncDescriptorError("restore transaction descriptor 初始化不完整")
        }
        self.homeDirectory = homeDirectory
        self.transactionName = transactionName
        self.transactionRootURL = rootURL
        self.transaction = transaction
        self.originals = openedOriginals
        self.replacements = openedReplacements
        self.discarded = openedDiscarded
        self.recovery = openedRecovery
        self.willApply = willApply
        self.destinationWillJournal = destinationWillJournal
        self.willVerifyApplied = willVerifyApplied
        self.willCompensate = willCompensate
        self.willVerifyCompensated = willVerifyCompensated
        self.journalWillOpen = journalWillOpen
        self.journalDidRead = journalDidRead
        self.cleanupWillBegin = cleanupWillBegin
        self.cleanupDidRemoveEntry = cleanupDidRemoveEntry
        self.cleanupWillRemoveRoot = cleanupWillRemoveRoot
        self.lastKnownJournalPath = rootURL
        self.operations = prepared
        self.createdDirectories = Array(Set(createdDirectories))
    }

    func apply() throws {
        for index in operations.indices {
            do {
                let destination = operations[index].destination
                try homeDirectory.verifyParent(destination)
                let destinationMetadata = try homeDirectory.entryMetadata(destination)
                let destinationExisted = destinationMetadata != nil
                operations[index].destinationExisted = destinationExisted
                if destinationExisted {
                    guard let destinationMetadata,
                          (destinationMetadata.st_mode & S_IFMT) == S_IFREG else {
                        throw NSError(
                            domain: "CodexTokenBar",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "回滚目标不是常规文件：\(destination.displayURL.path)"]
                        )
                    }
                    let destinationIdentity = ProviderSyncFileIdentity(destinationMetadata)
                    let original = try homeDirectory.readRegularFile(
                        destination,
                        expectedIdentity: destinationIdentity
                    )
                    guard let currentMetadata = try homeDirectory.entryMetadata(destination),
                          ProviderSyncFileIdentity(currentMetadata) == original.identity else {
                        throw providerSyncDescriptorError(
                            "journal 前目标身份发生变化：\(destination.displayURL.path)"
                        )
                    }
                    operations[index].originalDigest = providerSyncSHA256Hex(original.data)
                    operations[index].originalIdentity = original.identity
                    try providerSyncCreateRegularFile(
                        directory: originals.rawValue,
                        name: operations[index].originalName,
                        data: Data()
                    )
                    guard let placeholderMetadata = try providerSyncEntryMetadata(
                        directory: originals.rawValue,
                        name: operations[index].originalName
                    ) else {
                        throw providerSyncDescriptorError("restore journal placeholder 缺失")
                    }
                    let placeholderIdentity = ProviderSyncFileIdentity(placeholderMetadata)
                    operations[index].placeholderIdentity = placeholderIdentity
                    try destinationWillJournal?(index, destination.displayURL)
                    try exchangeRequiringIdentities(
                        firstDirectory: destination.parent.rawValue,
                        firstName: destination.name,
                        expectedFirst: original.identity,
                        secondDirectory: originals.rawValue,
                        secondName: operations[index].originalName,
                        expectedSecond: placeholderIdentity,
                        context: "destination journal exchange",
                        recoveryPaths: [
                            destination.displayURL.path,
                            journalEntryURL(index: index).path
                        ]
                    )
                } else {
                    try destinationWillJournal?(index, destination.displayURL)
                }
                operations[index].journaled = true
                journaledIndices.append(index)
                try willApply?(index, destination.displayURL)
                try homeDirectory.verifyParent(destination)
                if let replacementName = operations[index].replacementName,
                   let replacementIdentity = operations[index].replacementIdentity {
                    if destinationExisted {
                        guard let placeholderIdentity = operations[index].placeholderIdentity else {
                            throw providerSyncDescriptorError("restore destination placeholder identity 缺失")
                        }
                        try exchangeRequiringIdentities(
                            firstDirectory: replacements.rawValue,
                            firstName: replacementName,
                            expectedFirst: replacementIdentity,
                            secondDirectory: destination.parent.rawValue,
                            secondName: destination.name,
                            expectedSecond: placeholderIdentity,
                            context: "restore replacement exchange",
                            recoveryPaths: [
                                replacementEntryURL(name: replacementName).path,
                                destination.displayURL.path
                            ]
                        )
                    } else {
                        try moveExclusiveRequiringIdentity(
                            fromDirectory: replacements.rawValue,
                            fromName: replacementName,
                            toDirectory: destination.parent.rawValue,
                            toName: destination.name,
                            expectedIdentity: replacementIdentity,
                            context: "restore replacement exclusive move",
                            recoveryPaths: [
                                replacementEntryURL(name: replacementName).path,
                                destination.displayURL.path
                            ]
                        )
                    }
                    operations[index].appliedIdentity = replacementIdentity
                } else if destinationExisted {
                    guard let placeholderIdentity = operations[index].placeholderIdentity else {
                        throw providerSyncDescriptorError("restore deletion placeholder identity 缺失")
                    }
                    let cleanupName = "placeholder-\(index)-\(UUID().uuidString)"
                    try moveExclusiveRequiringIdentity(
                        fromDirectory: destination.parent.rawValue,
                        fromName: destination.name,
                        toDirectory: replacements.rawValue,
                        toName: cleanupName,
                        expectedIdentity: placeholderIdentity,
                        context: "restore deletion placeholder move",
                        recoveryPaths: [
                            destination.displayURL.path,
                            replacementEntryURL(name: cleanupName).path
                        ]
                    )
                    operations[index].placeholderCleanupName = cleanupName
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

    func verifyAppliedState(invokeHooks: Bool = true) throws {
        try homeDirectory.verifyRootPathIdentity()
        for (index, operation) in operations.enumerated() where operation.applied {
            if invokeHooks {
                try willVerifyApplied?(index, operation.destination.displayURL)
            }
            try homeDirectory.verifyParent(operation.destination)
            if let expectedDigest = operation.expectedDigest {
                guard let appliedIdentity = operation.appliedIdentity else {
                    throw providerSyncDescriptorError("restore applied identity 缺失")
                }
                let applied = try homeDirectory.readRegularFile(
                    operation.destination,
                    expectedIdentity: appliedIdentity
                )
                guard providerSyncSHA256Hex(applied.data) == expectedDigest else {
                    throw NSError(
                        domain: "CodexTokenBar",
                        code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "回滚目标内容校验失败：\(operation.destination.displayURL.path)"]
                    )
                }
            } else if try homeDirectory.entryMetadata(operation.destination) != nil {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "回滚目标应保持不存在：\(operation.destination.displayURL.path)"]
                )
            }
            if operation.destinationExisted {
                guard let originalIdentity = operation.originalIdentity,
                      let journalMetadata = try providerSyncEntryMetadata(
                        directory: originals.rawValue,
                        name: operation.originalName
                      ),
                      ProviderSyncFileIdentity(journalMetadata) == originalIdentity else {
                    throw ProviderSyncIdentityConflictError(
                        message: "restore journal identity 在 applied verification 前发生变化",
                        recoveryPaths: [journalEntryURL(index: index).path]
                    )
                }
            }
        }
    }

    func compensate() throws {
        guard !finished else { return }
        guard preservationFailures.isEmpty else {
            throw NSError(
                domain: "CodexTokenBar",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "identity revert 未完成，已保留 journal：\(journalPath.path)；\(preservationFailures.joined(separator: "；"))"
                ]
            )
        }
        var failures: [String] = []
        for index in journaledIndices.reversed() where !operations[index].compensated {
            do {
                try compensateOperation(index)
                try verifyCompensatedState(index)
                operations[index].compensated = true
            } catch {
                failures.append("\(operations[index].destination.displayURL.path)：\(error.localizedDescription)")
            }
        }
        for index in journaledIndices where operations[index].compensated {
            do {
                try verifyCompensatedState(index)
            } catch {
                operations[index].compensated = false
                failures.append("\(operations[index].destination.displayURL.path)：\(error.localizedDescription)")
            }
        }
        guard failures.isEmpty,
              journaledIndices.allSatisfy({ operations[$0].compensated }) else {
            throw NSError(
                domain: "CodexTokenBar",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey: "补偿未完整恢复，已保留 journal：\(journalPath.path)；\(failures.joined(separator: "；"))"
                ]
            )
        }
        try cleanupTransactionRoot()
        finished = true
        removeCreatedDirectoriesIfEmpty()
    }

    func commit() throws {
        guard !finished else { return }
        do {
            try cleanupTransactionRoot()
            finished = true
        } catch {
            throw ProviderSyncRestoreCommitError(
                journalPath: journalPath,
                underlying: error
            )
        }
    }

    private func compensateOperation(_ index: Int) throws {
        let operation = operations[index]
        try willCompensate?(index, operation.destination.displayURL)
        try homeDirectory.verifyParent(operation.destination)
        let original: ProviderSyncRegularFileSnapshot?
        if operation.destinationExisted {
            guard let originalIdentity = operation.originalIdentity else {
                throw providerSyncDescriptorError("journal original identity 缺失：\(operation.originalName)")
            }
            original = try providerSyncReadRegularFile(
                directory: originals.rawValue,
                name: operation.originalName,
                expectedIdentity: originalIdentity,
                willOpen: {
                    try self.journalWillOpen?(index, self.journalEntryURL(index: index))
                },
                didRead: {
                    try self.journalDidRead?(index, self.journalEntryURL(index: index))
                }
            )
        } else {
            original = nil
        }

        if let destinationMetadata = try homeDirectory.entryMetadata(operation.destination) {
            let expectedCurrentIdentity = operation.appliedIdentity ?? operation.placeholderIdentity
            guard let expectedCurrentIdentity else {
                throw ProviderSyncIdentityConflictError(
                    message: "compensation 发现未归属的 destination entry",
                    recoveryPaths: [operation.destination.displayURL.path, journalPath.path]
                )
            }
            let discardedName = "\(index)-\(UUID().uuidString)"
            guard ProviderSyncFileIdentity(destinationMetadata) == expectedCurrentIdentity else {
                throw ProviderSyncIdentityConflictError(
                    message: "compensation destination identity 发生变化",
                    recoveryPaths: [operation.destination.displayURL.path, journalPath.path]
                )
            }
            try moveExclusiveRequiringIdentity(
                fromDirectory: operation.destination.parent.rawValue,
                fromName: operation.destination.name,
                toDirectory: discarded.rawValue,
                toName: discardedName,
                expectedIdentity: expectedCurrentIdentity,
                context: "compensation discarded move",
                recoveryPaths: [
                    operation.destination.displayURL.path,
                    journalPath.appendingPathComponent("discarded/\(discardedName)").path
                ]
            )
            discardedNames.append(discardedName)
        }
        if let original {
            let recoveryName = "\(index)-\(UUID().uuidString)"
            try providerSyncCreateRegularFile(
                directory: recovery.rawValue,
                name: recoveryName,
                data: original.data,
                metadata: original.metadata
            )
            recoveryNames.append(recoveryName)
            guard let recoveryMetadata = try providerSyncEntryMetadata(
                directory: recovery.rawValue,
                name: recoveryName
            ) else {
                throw providerSyncDescriptorError("compensation recovery entry 缺失")
            }
            let recoveryIdentity = ProviderSyncFileIdentity(recoveryMetadata)
            try homeDirectory.verifyParent(operation.destination)
            try moveExclusiveRequiringIdentity(
                fromDirectory: recovery.rawValue,
                fromName: recoveryName,
                toDirectory: operation.destination.parent.rawValue,
                toName: operation.destination.name,
                expectedIdentity: recoveryIdentity,
                context: "compensation recovery placement",
                recoveryPaths: [
                    journalPath.appendingPathComponent("recovery/\(recoveryName)").path,
                    operation.destination.displayURL.path
                ]
            )
            operations[index].compensatedIdentity = recoveryIdentity
        }
    }

    private func verifyCompensatedState(_ index: Int) throws {
        let operation = operations[index]
        try willVerifyCompensated?(index, operation.destination.displayURL)
        try homeDirectory.verifyParent(operation.destination)
        if operation.destinationExisted {
            guard let originalDigest = operation.originalDigest,
                  let compensatedIdentity = operation.compensatedIdentity else {
                throw providerSyncDescriptorError("compensated destination identity 缺失")
            }
            let compensated = try homeDirectory.readRegularFile(
                operation.destination,
                expectedIdentity: compensatedIdentity
            )
            guard providerSyncSHA256Hex(compensated.data) == originalDigest else {
                throw NSError(
                    domain: "CodexTokenBar",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "补偿后原始内容校验失败：\(operation.destination.displayURL.path)"]
                )
            }
        } else if try homeDirectory.entryMetadata(operation.destination) != nil {
            throw NSError(
                domain: "CodexTokenBar",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "补偿后目标应保持不存在：\(operation.destination.displayURL.path)"]
            )
        }
    }

    private func journalEntryURL(index: Int) -> URL {
        journalPath
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(operations[index].originalName)
    }

    private func replacementEntryURL(name: String) -> URL {
        journalPath
            .appendingPathComponent("replacements", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func entryIdentity(directory: Int32, name: String) throws -> ProviderSyncFileIdentity? {
        try providerSyncEntryMetadata(directory: directory, name: name)
            .map(ProviderSyncFileIdentity.init)
    }

    private func exchangeRequiringIdentities(
        firstDirectory: Int32,
        firstName: String,
        expectedFirst: ProviderSyncFileIdentity,
        secondDirectory: Int32,
        secondName: String,
        expectedSecond: ProviderSyncFileIdentity,
        context: String,
        recoveryPaths: [String]
    ) throws {
        try providerSyncExchange(
            firstDirectory: firstDirectory,
            firstName: firstName,
            secondDirectory: secondDirectory,
            secondName: secondName
        )
        let observedFirst = try entryIdentity(directory: firstDirectory, name: firstName)
        let observedSecond = try entryIdentity(directory: secondDirectory, name: secondName)
        guard observedFirst == expectedSecond, observedSecond == expectedFirst else {
            do {
                try providerSyncExchange(
                    firstDirectory: firstDirectory,
                    firstName: firstName,
                    secondDirectory: secondDirectory,
                    secondName: secondName
                )
                let revertedFirst = try entryIdentity(directory: firstDirectory, name: firstName)
                let revertedSecond = try entryIdentity(directory: secondDirectory, name: secondName)
                guard revertedFirst == observedSecond, revertedSecond == observedFirst else {
                    preservationFailures.append("\(context) revert 后 identity 无法确认：\(recoveryPaths.joined(separator: "，"))")
                    throw ProviderSyncIdentityConflictError(
                        message: "\(context) identity mismatch 且 revert 无法确认",
                        recoveryPaths: recoveryPaths
                    )
                }
            } catch let conflict as ProviderSyncIdentityConflictError {
                throw conflict
            } catch {
                preservationFailures.append("\(context) revert 失败：\(error.localizedDescription)")
                throw ProviderSyncIdentityConflictError(
                    message: "\(context) identity mismatch 且 revert 失败",
                    recoveryPaths: recoveryPaths
                )
            }
            throw ProviderSyncIdentityConflictError(
                message: "\(context) identity mismatch，已 atomic revert",
                recoveryPaths: recoveryPaths
            )
        }
    }

    private func moveExclusiveRequiringIdentity(
        fromDirectory: Int32,
        fromName: String,
        toDirectory: Int32,
        toName: String,
        expectedIdentity: ProviderSyncFileIdentity,
        context: String,
        recoveryPaths: [String]
    ) throws {
        try providerSyncRenameExclusive(
            fromDirectory: fromDirectory,
            fromName: fromName,
            toDirectory: toDirectory,
            toName: toName
        )
        let observed = try entryIdentity(directory: toDirectory, name: toName)
        guard observed == expectedIdentity else {
            do {
                try providerSyncRenameExclusive(
                    fromDirectory: toDirectory,
                    fromName: toName,
                    toDirectory: fromDirectory,
                    toName: fromName
                )
                guard try entryIdentity(directory: fromDirectory, name: fromName) == observed else {
                    preservationFailures.append("\(context) revert 后 identity 无法确认：\(recoveryPaths.joined(separator: "，"))")
                    throw ProviderSyncIdentityConflictError(
                        message: "\(context) moved identity mismatch 且 revert 无法确认",
                        recoveryPaths: recoveryPaths
                    )
                }
            } catch let conflict as ProviderSyncIdentityConflictError {
                throw conflict
            } catch {
                preservationFailures.append("\(context) revert 失败：\(error.localizedDescription)")
                throw ProviderSyncIdentityConflictError(
                    message: "\(context) moved identity mismatch 且 revert 失败",
                    recoveryPaths: recoveryPaths
                )
            }
            throw ProviderSyncIdentityConflictError(
                message: "\(context) moved identity mismatch，已 revert",
                recoveryPaths: recoveryPaths
            )
        }
    }

    private func cleanupTransactionRoot() throws {
        if !cleanupDidBegin {
            cleanupDidBegin = true
            try cleanupWillBegin?(journalPath)
        }

        if !cleanupContentsRemoved {
            for operation in operations {
                try providerSyncUnlinkIfExists(
                    directory: originals.rawValue,
                    name: operation.originalName
                )
                if !cleanupDidReportPartialRemoval {
                    cleanupDidReportPartialRemoval = true
                    try cleanupDidRemoveEntry?(journalPath)
                }
                if let replacementName = operation.replacementName {
                    try providerSyncUnlinkIfExists(
                        directory: replacements.rawValue,
                        name: replacementName
                    )
                }
                if let placeholderCleanupName = operation.placeholderCleanupName,
                   placeholderCleanupName != operation.replacementName {
                    try providerSyncUnlinkIfExists(
                        directory: replacements.rawValue,
                        name: placeholderCleanupName
                    )
                }
            }
            for name in discardedNames {
                try providerSyncUnlinkIfExists(directory: discarded.rawValue, name: name)
            }
            for name in recoveryNames {
                try providerSyncUnlinkIfExists(directory: recovery.rawValue, name: name)
            }
            for operation in operations {
                guard try providerSyncEntryMetadata(
                    directory: originals.rawValue,
                    name: operation.originalName
                ) == nil else {
                    throw providerSyncDescriptorError("cleanup 后 journal original 仍存在：\(operation.originalName)")
                }
            }
            cleanupContentsRemoved = true
        }

        if !cleanupDirectoriesRemoved {
            try providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "originals", flags: AT_REMOVEDIR)
            try providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "replacements", flags: AT_REMOVEDIR)
            try providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "discarded", flags: AT_REMOVEDIR)
            try providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "recovery", flags: AT_REMOVEDIR)
            cleanupDirectoriesRemoved = true
        }

        if !cleanupDescriptorsClosed {
            try originals.close()
            try replacements.close()
            try discarded.close()
            try recovery.close()
            cleanupDescriptorsClosed = true
        }

        if !cleanupDidRequestRootRemoval {
            cleanupDidRequestRootRemoval = true
            try cleanupWillRemoveRoot?(journalPath)
        }
        try transaction.close()
        try providerSyncUnlinkIfExists(
            directory: homeDirectory.descriptor,
            name: transactionName,
            flags: AT_REMOVEDIR
        )
        guard try providerSyncEntryMetadata(
            directory: homeDirectory.descriptor,
            name: transactionName
        ) == nil else {
            throw providerSyncDescriptorError("transaction root cleanup 后仍存在：\(journalPath.path)")
        }
    }

    private static func cleanupInitializationFailure(
        homeDirectory: ProviderSyncHomeDirectory,
        transactionName: String,
        transaction: ProviderSyncOwnedFileDescriptor,
        originals: ProviderSyncOwnedFileDescriptor?,
        replacements: ProviderSyncOwnedFileDescriptor?,
        discarded: ProviderSyncOwnedFileDescriptor?,
        recovery: ProviderSyncOwnedFileDescriptor?,
        possibleEntryCount: Int
    ) {
        for index in 0..<possibleEntryCount {
            let name = String(index)
            if let originals {
                try? providerSyncUnlinkIfExists(directory: originals.rawValue, name: name)
            }
            if let replacements {
                try? providerSyncUnlinkIfExists(directory: replacements.rawValue, name: name)
            }
        }
        try? originals?.close()
        try? replacements?.close()
        try? discarded?.close()
        try? recovery?.close()
        try? providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "originals", flags: AT_REMOVEDIR)
        try? providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "replacements", flags: AT_REMOVEDIR)
        try? providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "discarded", flags: AT_REMOVEDIR)
        try? providerSyncUnlinkIfExists(directory: transaction.rawValue, name: "recovery", flags: AT_REMOVEDIR)
        try? transaction.close()
        try? providerSyncUnlinkIfExists(
            directory: homeDirectory.descriptor,
            name: transactionName,
            flags: AT_REMOVEDIR
        )
    }

    private func removeCreatedDirectoriesIfEmpty() {
        for directory in createdDirectories.sorted(by: { $0.count > $1.count }) {
            homeDirectory.removeCreatedDirectoryIfEmpty(relativePath: directory)
        }
    }
}

private func providerSyncPathExistsNoFollow(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
}

private func providerSyncPOSIXMessage() -> String {
    String(cString: strerror(errno))
}
