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
        try createSessionTar(files: sessionFiles, destination: backup.appendingPathComponent("session-jsonl.before.tar"))

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

    func createSessionTar(files: [URL], destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-C", "/", "-cf", destination.path] + files.map { String($0.path.dropFirst()) }
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
        return URL(fileURLWithPath: backedUpHome).standardizedFileURL.path == codexHome.standardizedFileURL.path
    }

    func restoreBackup(_ backup: URL, codexHome: URL) throws {
        guard backupMatchesCodexHome(backup, codexHome: codexHome) else {
            throw NSError(domain: "CodexTokenBar", code: 400, userInfo: [NSLocalizedDescriptionKey: "备份不属于当前 Codex Home，已拒绝回滚"])
        }

        try restoreFileIfBackedUp(backup.appendingPathComponent("config.toml.before"), to: codexHome.appendingPathComponent("config.toml"), removeIfMissing: false)
        let state = codexHome.appendingPathComponent("state_5.sqlite")
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("state_5.sqlite.before"), to: state, removeIfMissing: false)
        try removeSQLiteSidecars(for: state)
        try restoreFileIfBackedUp(backup.appendingPathComponent("session_index.jsonl.before"), to: codexHome.appendingPathComponent("session_index.jsonl"), removeIfMissing: true)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.before"), to: codexHome.appendingPathComponent(".codex-global-state.json"), removeIfMissing: false)
        try restoreFileIfBackedUp(backup.appendingPathComponent("codex-global-state.json.bak.before"), to: codexHome.appendingPathComponent(".codex-global-state.json.bak"), removeIfMissing: false)

        let tar = backup.appendingPathComponent("session-jsonl.before.tar")
        if fileManager.fileExists(atPath: tar.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-C", "/", "-xf", tar.path]
            let error = Pipe()
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar restore failed"
                throw NSError(domain: "CodexTokenBar", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
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
