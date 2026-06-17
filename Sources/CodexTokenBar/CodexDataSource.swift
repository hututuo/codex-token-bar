import Foundation

struct CodexDataSource: Equatable {
    let codexHome: URL
    let origin: Origin

    enum Origin: Equatable {
        case environment
        case defaultHome
        case oneLevelScan
        case userSelected
    }

    var sessionsRoot: URL {
        codexHome.appendingPathComponent("sessions")
    }

    var stateDatabase: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    var displayPath: String {
        Self.userFacingPath(codexHome)
    }

    var originLabel: String {
        switch origin {
        case .environment:
            return "CODEX_HOME"
        case .defaultHome:
            return "自动发现"
        case .oneLevelScan:
            return "一级扫描"
        case .userSelected:
            return "手动目录"
        }
    }

    var hasSessions: Bool {
        FileManager.default.fileExists(atPath: sessionsRoot.path)
    }

    var hasStateDatabase: Bool {
        FileManager.default.fileExists(atPath: stateDatabase.path)
    }

    private static func userFacingPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

final class CodexDataSourceResolver {
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let scopedAccess: SecurityScopedCodexDirectoryAccess
    private let selectedPathKey = "CodexTokenBar.selectedCodexHome"
    private let legacySelectedPathKey = "CodexTokenDashboard.selectedCodexHome"

    init(
        defaults: UserDefaults = .standard,
        scopedAccess: SecurityScopedCodexDirectoryAccess? = nil
    ) {
        self.defaults = defaults
        self.scopedAccess = scopedAccess ?? SecurityScopedCodexDirectoryAccess(defaults: defaults)
    }

    func resolve() -> CodexDataSource? {
        if let selected = selectedDataSource(), isUsable(selected) {
            return selected
        }

        for candidate in automaticCandidates() {
            if isUsable(candidate) {
                return candidate
            }
        }

        return nil
    }

    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? {
        let normalized = normalize(directory)
        scopedAccess.saveAccess(for: normalized)
        defaults.set(normalized.path, forKey: selectedPathKey)
        defaults.removeObject(forKey: legacySelectedPathKey)
        return selectedDataSource()
    }

    func selectedDataSource() -> CodexDataSource? {
        let bookmarkedURL = scopedAccess.restoreAccess()
        let currentPath = defaults.string(forKey: selectedPathKey)
        let legacyPath = defaults.string(forKey: legacySelectedPathKey)
        let selectedURL = bookmarkedURL ?? [currentPath, legacyPath]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
            .map { URL(fileURLWithPath: $0) }

        guard let selectedURL else {
            return nil
        }

        if currentPath == nil {
            defaults.set(selectedURL.path, forKey: selectedPathKey)
        }
        return CodexDataSource(codexHome: normalize(selectedURL), origin: .userSelected)
    }

    private func automaticCandidates() -> [CodexDataSource] {
        var candidates: [CodexDataSource] = []
        var seen = Set<String>()

        func append(_ url: URL, origin: CodexDataSource.Origin) {
            let normalized = normalize(url)
            guard seen.insert(normalized.path).inserted else { return }
            candidates.append(CodexDataSource(codexHome: normalized, origin: origin))
        }

        if let envPath = ProcessInfo.processInfo.environment["CODEX_HOME"], !envPath.isEmpty {
            append(URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath), origin: .environment)
        }

        let home = fileManager.homeDirectoryForCurrentUser
        append(home.appendingPathComponent(".codex"), origin: .defaultHome)
        append(home.appendingPathComponent(".config/codex"), origin: .oneLevelScan)

        for child in immediateDirectories(under: home) {
            append(child.appendingPathComponent(".codex"), origin: .oneLevelScan)
            if child.lastPathComponent.localizedCaseInsensitiveContains("codex") {
                append(child, origin: .oneLevelScan)
            }
        }

        return candidates
    }

    private func normalize(_ directory: URL) -> URL {
        let url = directory.resolvingSymlinksInPath()
        if url.lastPathComponent == "sessions" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private func isUsable(_ source: CodexDataSource) -> Bool {
        source.hasSessions || source.hasStateDatabase
    }

    private func immediateDirectories(under root: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
            return values.isDirectory == true
        }
    }
}
