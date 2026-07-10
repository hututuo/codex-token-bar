import Foundation

final class ProviderSyncPreparedSessionMutation {
    let binding: ProviderSyncSessionMutationBinding
    let file: ProviderSyncPinnedFile
    let source: ProviderSyncRegularFileSnapshot
    let replacementData: Data?
    var currentIdentity: ProviderSyncFileIdentity
    var replacement: ProviderSyncRegularFileReplacement?

    init(
        binding: ProviderSyncSessionMutationBinding,
        file: ProviderSyncPinnedFile,
        source: ProviderSyncRegularFileSnapshot,
        replacementData: Data?
    ) {
        self.binding = binding
        self.file = file
        self.source = source
        self.replacementData = replacementData
        currentIdentity = source.identity
        replacement = nil
    }

    var expectedData: Data {
        replacementData ?? source.data
    }
}

extension ProviderSyncEngine {
    func configProvider(homeDirectory: ProviderSyncHomeDirectory) throws -> String? {
        guard let data = try homeDirectory.readOptionalRegularFile(
            relativePath: "config.toml",
            requireSingleLink: true
        )?.data else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw providerSyncDescriptorError("config.toml 不是 UTF-8")
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let range = line.range(of: #"^\s*model_provider\s*=\s*"([^"]+)""#, options: .regularExpression) else { continue }
            let match = String(line[range])
            if let valueRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                return String(match[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    func findSessionFiles(codexHome: URL, includeArchivedSessions: Bool) -> [URL] {
        var roots = [codexHome.appendingPathComponent("sessions")]
        if includeArchivedSessions {
            roots.append(codexHome.appendingPathComponent("archived_sessions"))
        }
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                    files.append(file)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    func readSessionProvider(
        file: URL,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> String? {
        let canonicalHome = homeDirectory.canonicalURL.standardizedFileURL
        let standardizedFile = file.standardizedFileURL
        guard standardizedFile.path.hasPrefix(canonicalHome.path + "/") else {
            throw providerSyncDescriptorError("session 文件不在 pinned Codex Home 内：\(file.path)")
        }
        let relativePath = String(standardizedFile.path.dropFirst(canonicalHome.path.count + 1))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.first == "sessions" || components.first == "archived_sessions",
              relativePath.hasSuffix(".jsonl") else {
            throw providerSyncDescriptorError("session 文件路径不在允许范围内：\(relativePath)")
        }
        let snapshot = try homeDirectory.readOptionalRegularFile(
            relativePath: relativePath,
            requireSingleLink: true
        )
        guard let object = try snapshot.flatMap({ try readFirstLineJSON(data: $0.data) }),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        return (payload["model_provider"] as? String) ?? "(missing)"
    }

    func readFirstLineJSON(data: Data) throws -> [String: Any]? {
        guard let firstLine = readFirstLineData(data: data), !firstLine.isEmpty else { return nil }
        let value = try JSONSerialization.jsonObject(with: firstLine, options: [])
        return value as? [String: Any]
    }

    func readFirstLineData(data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        return Data(data[..<newline])
    }

    func prepareSessionMutations(
        homeDirectory: ProviderSyncHomeDirectory,
        bindings: [ProviderSyncSessionMutationBinding],
        targetProvider: String
    ) throws -> [ProviderSyncPreparedSessionMutation] {
        try bindings.map { binding in
            let file = try homeDirectory.pinFile(
                relativePath: binding.relativePath,
                createParents: false
            )
            let source = try homeDirectory.readRegularFile(
                file,
                expectedIdentity: binding.identity,
                requireSingleLink: true
            )
            guard providerSyncSHA256Hex(source.data) == binding.sha256 else {
                throw providerSyncDescriptorError(
                    "session 内容与已发布备份不一致：\(file.displayURL.path)"
                )
            }
            return ProviderSyncPreparedSessionMutation(
                binding: binding,
                file: file,
                source: source,
                replacementData: try rewrittenSessionData(
                    source.data,
                    targetProvider: targetProvider
                )
            )
        }
    }

    func applyPreparedSessionMutation(
        _ mutation: ProviderSyncPreparedSessionMutation,
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> Bool {
        guard let replacementData = mutation.replacementData else { return false }
        let replacement = try homeDirectory.replaceRegularFile(
            mutation.file,
            expectedIdentity: mutation.currentIdentity,
            data: replacementData,
            preserving: mutation.source.metadata,
            beforeExchange: {
                try self.sessionReplacementWillExchange?(mutation.file.displayURL)
            }
        )
        mutation.replacement = replacement
        mutation.currentIdentity = replacement.replacementIdentity
        return true
    }

    func commitPreparedSessionMutations(
        _ mutations: [ProviderSyncPreparedSessionMutation],
        homeDirectory: ProviderSyncHomeDirectory
    ) throws {
        for mutation in mutations {
            guard let replacement = mutation.replacement else { continue }
            try homeDirectory.commitRegularFileReplacement(replacement)
            mutation.replacement = nil
        }
    }

    func rollbackPreparedSessionMutations(
        _ mutations: [ProviderSyncPreparedSessionMutation],
        homeDirectory: ProviderSyncHomeDirectory
    ) throws {
        var failures: [String] = []
        for mutation in mutations.reversed() {
            guard let replacement = mutation.replacement else { continue }
            do {
                try homeDirectory.rollbackRegularFileReplacement(replacement)
                mutation.currentIdentity = replacement.originalIdentity
                mutation.replacement = nil
            } catch {
                failures.append("\(mutation.file.displayURL.path)：\(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw ProviderSyncIdentityConflictError(
                message: "session batch rollback 未完整恢复",
                recoveryPaths: failures
            )
        }
    }

    func validatePreparedSessionMutations(
        _ mutations: [ProviderSyncPreparedSessionMutation],
        homeDirectory: ProviderSyncHomeDirectory
    ) throws {
        for mutation in mutations {
            let snapshot = try homeDirectory.readRegularFile(
                mutation.file,
                expectedIdentity: mutation.currentIdentity,
                requireSingleLink: true
            )
            guard providerSyncSHA256Hex(snapshot.data) == providerSyncSHA256Hex(mutation.expectedData) else {
                throw providerSyncDescriptorError(
                    "session 写后内容发生变化：\(mutation.file.displayURL.path)"
                )
            }
        }
    }

    private func rewrittenSessionData(_ data: Data, targetProvider: String) throws -> Data? {
        guard let parts = firstLineParts(in: data), !parts.line.isEmpty else { return nil }

        guard var object = try JSONSerialization.jsonObject(with: parts.line, options: []) as? [String: Any],
              object["type"] as? String == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let currentProvider = payload["model_provider"] as? String
        guard currentProvider != targetProvider else { return nil }

        payload["model_provider"] = targetProvider
        object["payload"] = payload
        let updatedLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var output = Data()
        output.append(updatedLine)
        output.append(parts.separator)
        output.append(parts.rest)
        return output
    }

    func firstLineParts(in data: Data) -> (line: Data, separator: Data, rest: Data)? {
        guard !data.isEmpty else { return nil }
        guard let newline = data.firstIndex(of: 0x0A) else {
            return (data, Data(), Data())
        }

        let lineEnd: Data.Index
        let separatorStart: Data.Index
        if newline > data.startIndex {
            let previous = data.index(before: newline)
            if data[previous] == 0x0D {
                lineEnd = previous
                separatorStart = previous
            } else {
                lineEnd = newline
                separatorStart = newline
            }
        } else {
            lineEnd = newline
            separatorStart = newline
        }

        let restStart = data.index(after: newline)
        return (
            Data(data[data.startIndex..<lineEnd]),
            Data(data[separatorStart..<restStart]),
            Data(data[restStart..<data.endIndex])
        )
    }
}
