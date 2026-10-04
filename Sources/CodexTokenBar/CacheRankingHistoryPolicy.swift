import Foundation

/// Disposable ranking scope; never deletes or trims the exact history ledger.
enum CacheRankingHistoryPolicy {
    static let notice = "已开启历史压缩，仅显示最近 7 天活跃会话。较早的历史会话可能已压缩。"

    static func isEnabled(codexHome: URL) -> Bool {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        return isEnabled(configText: text)
    }

    /// Reads the boolean written by Codex Settings, including a root dotted key.
    /// Ignore comments and multiline strings so text inside a prompt is not a flag.
    static func isEnabled(configText: String) -> Bool {
        var table = ""
        var multiline: String?
        var enabled = false
        for raw in configText.components(separatedBy: .newlines) {
            if let delimiter = multiline {
                if raw.components(separatedBy: delimiter).count.isMultiple(of: 2) { multiline = nil }
                continue
            }
            var quote: Character?
            var escaped = false
            var line = ""
            for character in raw {
                if escaped { line.append(character); escaped = false; continue }
                if quote == "\"", character == "\\" { line.append(character); escaped = true; continue }
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "#" { break }
                else if character == "\"" || character == "'" { quote = character }
                line.append(character)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.dropFirst().dropLast().filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                if value.components(separatedBy: delimiter).count.isMultiple(of: 2) { multiline = delimiter }
            }
            if table.isEmpty, key == "features", value.hasPrefix("{"), value.hasSuffix("}") {
                enabled = inlineCompressionFlag(String(value.dropFirst().dropLast()))
            }
            if (table == "features" && key == "local_thread_store_compression")
                || (table.isEmpty && key == "features.local_thread_store_compression") {
                enabled = value == "true"
            }
        }
        return enabled
    }

    private static func inlineCompressionFlag(_ body: String) -> Bool {
        var entries: [String] = []
        var entry = ""
        var quote: Character?
        var escaped = false
        var nesting = 0
        for character in body {
            if escaped { entry.append(character); escaped = false; continue }
            if quote == "\"", character == "\\" { entry.append(character); escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "{" || character == "[" { nesting += 1 }
            else if character == "}" || character == "]" { nesting -= 1 }
            else if character == ",", nesting == 0 { entries.append(entry); entry = ""; continue }
            entry.append(character)
        }
        entries.append(entry)
        for entry in entries {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<equals].filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            if key == "local_thread_store_compression" {
                return entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces) == "true"
            }
        }
        return false
    }

}

extension TokenCacheUsage {
    func withRankingSessions(_ sessions: [SessionCacheUsage], activeSince: Date) -> TokenCacheUsage {
        var result = self
        result.sessions = sessions
        result.rankingActiveSince = activeSince
        return result
    }
}
