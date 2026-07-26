import Darwin
import Foundation

extension ProviderSyncEngine {
    func openProviderBackupRoot() throws -> (
        url: URL,
        directory: ProviderSyncHomeDirectory
    ) {
        let requestedRoot = backupRootDirectory().standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: requestedRoot.path,
            isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue else {
                throw providerSyncDescriptorError(
                    "Provider 备份根路径不是目录：\(requestedRoot.path)"
                )
            }
        } else {
            try fileManager.createDirectory(
                at: requestedRoot,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: requestedRoot.path
            )
        }
        let canonicalRoot = requestedRoot.resolvingSymlinksInPath()
        let directory = try ProviderSyncHomeDirectory(
            canonicalURL: canonicalRoot
        )
        try directory.verifyRootPathIdentity()
        return (canonicalRoot, directory)
    }

    func publishProviderBackup(
        staging: URL,
        destination: URL,
        backupRoot: ProviderSyncHomeDirectory
    ) throws {
        try backupRoot.verifyRootPathIdentity()
        try fileManager.moveItem(at: staging, to: destination)
        do {
            try backupRoot.syncRootDirectory()
        } catch let durabilityError {
            do {
                try fileManager.removeItem(at: destination)
                try backupRoot.syncRootDirectory()
            } catch let cleanupError {
                throw ProviderSyncIdentityConflictError(
                    message: "Provider 恢复点已发布，但目录持久化失败且无法清理：\(durabilityError.localizedDescription)；\(cleanupError.localizedDescription)",
                    recoveryPaths: [destination.path]
                )
            }
            throw providerSyncDescriptorError(
                "Provider 恢复点目录持久化失败，已移除未确认发布物：\(durabilityError.localizedDescription)"
            )
        }
    }

    func validatedProviderBackupDirectory(
        _ backupURL: URL,
        canonicalRoot: URL
    ) throws -> URL {
        let standardizedBackup = backupURL.standardizedFileURL
        var metadata = stat()
        guard lstat(standardizedBackup.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw providerSyncDescriptorError(
                "Provider 恢复点不是无跟随目录：\(standardizedBackup.path)"
            )
        }
        let canonicalBackup = standardizedBackup.resolvingSymlinksInPath()
        guard canonicalBackup.deletingLastPathComponent() == canonicalRoot else {
            throw providerSyncDescriptorError(
                "Provider 恢复点不属于当前备份根目录"
            )
        }
        return canonicalBackup
    }

    func providerConfigStringValue(
        _ key: String,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> String? {
        guard let data = try homeDirectory.readOptionalRegularFile(
            relativePath: "config.toml",
            requireSingleLink: true
        )?.data else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw providerSyncDescriptorError("config.toml 不是 UTF-8")
        }
        return try providerSyncTopLevelStringValues(text)[key]
    }

    func resolvedSQLiteHome(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> URL {
        if let configured = try providerConfigStringValue(
            "sqlite_home",
            homeDirectory: homeDirectory
        ) {
            let expanded = NSString(string: configured).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw providerSyncDescriptorError(
                    "config.toml 的 sqlite_home 必须是绝对路径：\(configured)"
                )
            }
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }

        if let raw = ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            let resolved = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : URL(
                    fileURLWithPath: fileManager.currentDirectoryPath,
                    isDirectory: true
                ).appendingPathComponent(expanded, isDirectory: true)
            return resolved.standardizedFileURL.resolvingSymlinksInPath()
        }

        return codexHome.standardizedFileURL.resolvingSymlinksInPath()
    }

    func withProviderSQLiteHome<T>(
        codexHome: URL,
        homeDirectory: ProviderSyncHomeDirectory,
        _ body: (URL, ProviderSyncHomeDirectory) throws -> T
    ) throws -> T {
        let sqliteHome = try resolvedSQLiteHome(
            codexHome: codexHome,
            homeDirectory: homeDirectory
        )
        let sqliteDirectory = try ProviderSyncHomeDirectory(canonicalURL: sqliteHome)
        defer { try? sqliteDirectory.close() }
        try homeDirectory.verifyRootPathIdentity()
        try sqliteDirectory.verifyRootPathIdentity()
        let result = try body(sqliteHome, sqliteDirectory)
        try homeDirectory.verifyRootPathIdentity()
        try sqliteDirectory.verifyRootPathIdentity()
        return result
    }
}

private func providerSyncTopLevelStringValues(_ text: String) throws -> [String: String] {
    var values: [String: String] = [:]
    var enteredTable = false
    var multilineDelimiter: String?

    for (offset, rawLine) in text.split(
        separator: "\n",
        omittingEmptySubsequences: false
    ).enumerated() {
        let sourceLine = String(rawLine)
        if let delimiter = multilineDelimiter {
            if providerSyncTripleQuoteCount(
                in: sourceLine,
                delimiter: delimiter
            ).isMultiple(of: 2) == false {
                multilineDelimiter = nil
            }
            continue
        }
        let line = providerSyncStripTOMLComment(sourceLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            continue
        }
        if line.hasPrefix("[") {
            enteredTable = true
            continue
        }
        if enteredTable {
            continue
        }
        guard let equals = line.firstIndex(of: "=") else {
            continue
        }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openingDelimiter: String?
        if rawValue.hasPrefix("\"\"\"") {
            openingDelimiter = "\"\"\""
        } else if rawValue.hasPrefix("'''") {
            openingDelimiter = "'''"
        } else {
            openingDelimiter = nil
        }
        if let openingDelimiter,
           providerSyncTripleQuoteCount(
               in: rawValue,
               delimiter: openingDelimiter
           ).isMultiple(of: 2) == false {
            multilineDelimiter = openingDelimiter
        }
        guard key == "model_provider" || key == "sqlite_home" else {
            continue
        }
        if openingDelimiter != nil {
            throw providerSyncDescriptorError(
                "config.toml 第 \(offset + 1) 行的 \(key) 必须是单行字符串"
            )
        }
        let value = rawValue
        let parsed: String
        if value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
           ) as? String {
            parsed = decoded
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            parsed = String(value.dropFirst().dropLast())
        } else {
            throw providerSyncDescriptorError(
                "config.toml 的 \(key) 必须是字符串"
            )
        }
        let trimmed = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw providerSyncDescriptorError("config.toml 的 \(key) 不能为空")
        }
        values[key] = trimmed
    }
    return values
}

private func providerSyncTripleQuoteCount(
    in value: some StringProtocol,
    delimiter: String
) -> Int {
    String(value).components(separatedBy: delimiter).count - 1
}

private func providerSyncStripTOMLComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
            continue
        }
        if quote == "\"", character == "\\" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
            continue
        }
        if character == "#", quote == nil {
            return String(line[..<index])
        }
    }
    return line
}
