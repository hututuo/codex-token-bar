import AgentSpeedCore
import Foundation

enum AntigravityUsageSource {
    private static let priceIdentifiers = Set(PriceBook.bundled.models.flatMap { [$0.id] + $0.aliases })
    /// Only the bundled, explicitly listed effort modifiers may use a known base
    /// price. Preserve the recorded model identity; never guess opaque router names.
    static func priceModel(for raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let table = PriceBook.bundled
        func exact(_ value: String) -> Bool { priceIdentifiers.contains(value) }
        if exact(key) || table.unknown.contains(where: { $0.isPrefix ? key.hasPrefix($0.value) : key == $0.value }) { return raw }
        for rule in table.normalize.modifierSuffixes where key.hasPrefix(rule.prefix) {
            for suffix in rule.suffixes where key.hasSuffix(suffix) {
                let base = String(key.dropLast(suffix.count))
                if exact(base) { return base }
            }
        }
        return raw
    }

    static func roots(home: URL, path: String = "") -> [URL] {
        let selected = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let stores = selected.isEmpty
            ? ["antigravity-cli", "antigravity", "antigravity-ide"].map { home.appendingPathComponent(".gemini/" + $0) }
            : [URL(fileURLWithPath: (selected as NSString).expandingTildeInPath)]
        return stores.map { $0.lastPathComponent == "conversations" ? $0 : $0.appendingPathComponent("conversations") }
            .filter { !$0.deletingLastPathComponent().lastPathComponent.hasSuffix("-backup") }
    }

    static func isConversation(_ url: URL) -> Bool {
        url.pathExtension == "db" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            && url.lastPathComponent.utf8.count == 39
    }

    static func discover(home: URL, path: String = "") -> MultiClientUsageDiscovery.Result {
        var files: [URL] = [], visited = 0
        for root in roots(home: home, path: path) {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                visited += 1
                if visited > MultiClientUsageDiscovery.maximumVisitedEntries || files.count >= MultiClientUsageDiscovery.maximumFiles {
                    return .init(files: files.sorted { $0.path < $1.path }, truncated: true)
                }
                let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if isConversation(url), info?.isRegularFile == true, info?.isSymbolicLink != true { files.append(url) }
            }
        }
        return .init(files: files.sorted { $0.path < $1.path }, truncated: false)
    }

    static func read(_ url: URL) throws -> (events: [ClientUsageEvent], malformedRows: Int) {
        let read = try AntigravityUsageRead.read(path: url.path)
        let session = url.deletingPathExtension().lastPathComponent
        return (read.responses.map { record in
            ClientUsageEvent(client: .antigravity, eventID: "antigravity:" + record.key, sessionID: session,
                model: record.model ?? "unknown", timestamp: Date(timeIntervalSince1970: Double(record.endMs) / 1000),
                inputTokens: Int64(record.usage.input), outputTokens: Int64(record.usage.output),
                cacheReadTokens: Int64(record.usage.cachedInput), cacheWriteTokens: 0,
                reasoningTokens: Int64(record.usage.reasoning))
        }, read.malformedRows)
    }
}
