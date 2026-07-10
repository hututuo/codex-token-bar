import Foundation

struct CodexHomeIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64

    static func read(at directory: URL, fileManager: FileManager = .default) -> CodexHomeIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return CodexHomeIdentity(deviceID: deviceID, fileID: fileID)
    }
}

struct CodexDataSource: Equatable, Sendable {
    let codexHome: URL
    let origin: Origin
    let homeIdentity: CodexHomeIdentity?

    enum Origin: Equatable, Sendable {
        case environment
        case defaultHome
        case oneLevelScan
        case userSelected
    }

    init(
        codexHome: URL,
        origin: Origin,
        expectedHomeIdentity: CodexHomeIdentity? = nil
    ) {
        let standardizedHome = codexHome.standardizedFileURL
        if let expectedHomeIdentity {
            self.codexHome = standardizedHome
            homeIdentity = expectedHomeIdentity
        } else {
            let canonicalHome = standardizedHome.resolvingSymlinksInPath()
            self.codexHome = canonicalHome
            homeIdentity = CodexHomeIdentity.read(at: canonicalHome)
        }
        self.origin = origin
    }

    var sessionsRoot: URL {
        codexHome.appendingPathComponent("sessions")
    }

    var stateDatabase: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    var stableIdentityKey: String {
        guard let homeIdentity else {
            return "path:\(codexHome.path)"
        }
        return "fs:\(homeIdentity.deviceID):\(homeIdentity.fileID)"
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
    private let selectedDeviceIDKey = "CodexTokenBar.selectedCodexHomeDeviceID"
    private let selectedFileIDKey = "CodexTokenBar.selectedCodexHomeFileID"

    init(
        defaults: UserDefaults = .standard,
        scopedAccess: SecurityScopedCodexDirectoryAccess? = nil
    ) {
        self.defaults = defaults
        self.scopedAccess = scopedAccess ?? SecurityScopedCodexDirectoryAccess(defaults: defaults)
    }

    func resolve() -> CodexDataSource? {
        if let selected = selectedDataSource() {
            return selected
        }
        if hasPersistedSelection {
            return nil
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
        guard let identity = CodexHomeIdentity.read(at: normalized) else {
            return nil
        }
        scopedAccess.saveAccess(for: normalized)
        persistSelection(path: normalized.path, identity: identity)
        return CodexDataSource(
            codexHome: normalized,
            origin: .userSelected,
            expectedHomeIdentity: identity
        )
    }

    func selectedDataSource() -> CodexDataSource? {
        let bookmarkedURL = scopedAccess.restoreAccess()
        let currentPath = defaults.string(forKey: selectedPathKey)
        let legacyPath = defaults.string(forKey: legacySelectedPathKey)
        let persistedPath = [currentPath, legacyPath]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
        let selectedURL = bookmarkedURL ?? [currentPath, legacyPath]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
            .map { URL(fileURLWithPath: $0) }

        guard let selectedURL else {
            return nil
        }

        let normalized = normalize(selectedURL)
        if let expectedIdentity = persistedSelectedIdentity() {
            if CodexHomeIdentity.read(at: normalized) == expectedIdentity {
                if currentPath != normalized.path {
                    scopedAccess.saveAccess(for: normalized)
                    persistSelection(path: normalized.path, identity: expectedIdentity)
                }
                return CodexDataSource(
                    codexHome: normalized,
                    origin: .userSelected,
                    expectedHomeIdentity: expectedIdentity
                )
            }

            let pinnedURL = persistedPath.map(lexicallyNormalizedHome) ?? normalized
            return CodexDataSource(
                codexHome: pinnedURL,
                origin: .userSelected,
                expectedHomeIdentity: expectedIdentity
            )
        }

        guard let identity = CodexHomeIdentity.read(at: normalized) else {
            return CodexDataSource(codexHome: normalized, origin: .userSelected)
        }
        persistSelection(path: normalized.path, identity: identity)
        return CodexDataSource(
            codexHome: normalized,
            origin: .userSelected,
            expectedHomeIdentity: identity
        )
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

    private var hasPersistedSelection: Bool {
        defaults.string(forKey: selectedPathKey) != nil
            || defaults.string(forKey: legacySelectedPathKey) != nil
    }

    private func persistedSelectedIdentity() -> CodexHomeIdentity? {
        guard let deviceID = defaults.string(forKey: selectedDeviceIDKey).flatMap(UInt64.init),
              let fileID = defaults.string(forKey: selectedFileIDKey).flatMap(UInt64.init) else {
            return nil
        }
        return CodexHomeIdentity(deviceID: deviceID, fileID: fileID)
    }

    private func persistSelection(path: String, identity: CodexHomeIdentity) {
        defaults.set(path, forKey: selectedPathKey)
        defaults.set(String(identity.deviceID), forKey: selectedDeviceIDKey)
        defaults.set(String(identity.fileID), forKey: selectedFileIDKey)
        defaults.removeObject(forKey: legacySelectedPathKey)
    }

    private func lexicallyNormalizedHome(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
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
