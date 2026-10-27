import Foundation
import Darwin

enum ConfiguredModes {
    static func codex(sessionsRoot: String) -> ExecutionModes {
        let directory = (sessionsRoot as NSString).lastPathComponent == "sessions"
            ? (sessionsRoot as NSString).deletingLastPathComponent : sessionsRoot
        let path = (directory as NSString).appendingPathComponent("config.toml")
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .empty }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let stat = FileStat.fstat(descriptor), stat.isRegularFile, stat.size <= 65_536,
              let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8), let tier = declaredTier(text) else { return .empty }
        return ExecutionModeAdapters.openAI(tier, evidence: .configured, scope: .configuration)
    }

    /// Only a literal root setting is claimed; this is not Codex's layered effective configuration.
    static func declaredTier(_ text: String) -> String? {
        var tier: String?
        var declared = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.contains("\"\"\"") || line.contains("'''") { return nil }
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "service_tier" else { continue }
            guard !declared else { return nil }
            declared = true
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            let tail = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            let native = String(value[value.index(after: value.startIndex)..<end])
            guard (tail.isEmpty || tail.hasPrefix("#")), ExecutionModeFact.isIdentifier(native, limit: 64) else { return nil }
            tier = native
        }
        return tier
    }
}
