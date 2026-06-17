import Foundation

extension ProviderSyncEngine {
    func configProvider(codexHome: URL) throws -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard fileManager.fileExists(atPath: config.path) else { return nil }
        let text = try String(contentsOf: config, encoding: .utf8)
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

    func newestSessionProvider(in files: [URL]) throws -> (provider: String?, file: URL?) {
        let sorted = files.sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in sorted {
            if let provider = try readSessionProvider(file: file) {
                return (provider, file)
            }
        }
        return (nil, nil)
    }

    func readSessionProvider(file: URL) throws -> String? {
        guard let object = try readFirstLineJSON(file: file),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        return (payload["model_provider"] as? String) ?? "(missing)"
    }

    func readFirstLineJSON(file: URL) throws -> [String: Any]? {
        guard let firstLine = try readFirstLineData(file: file), !firstLine.isEmpty else { return nil }
        let value = try JSONSerialization.jsonObject(with: firstLine, options: [])
        return value as? [String: Any]
    }

    func readFirstLineData(file: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else {
                return buffer.isEmpty ? nil : buffer
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[..<newline])
                return buffer
            }
            buffer.append(chunk)
        }
    }

    func rewriteSessionMetaProvider(file: URL, targetProvider: String) throws -> Bool {
        let originalModificationDate = modificationDate(of: file)
        let data = try Data(contentsOf: file)
        guard let parts = firstLineParts(in: data), !parts.line.isEmpty else { return false }

        guard var object = try JSONSerialization.jsonObject(with: parts.line, options: []) as? [String: Any],
              object["type"] as? String == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return false
        }
        let currentProvider = payload["model_provider"] as? String
        guard currentProvider != targetProvider else { return false }

        payload["model_provider"] = targetProvider
        object["payload"] = payload
        let updatedLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var output = Data()
        output.append(updatedLine)
        output.append(parts.separator)
        output.append(parts.rest)
        try output.write(to: file, options: [.atomic])
        restoreModificationDate(originalModificationDate, for: file)
        return true
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
