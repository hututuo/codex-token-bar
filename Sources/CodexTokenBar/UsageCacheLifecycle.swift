import Foundation

enum UsageCacheLifecycle {
    static let appDirectoryName = "CodexTokenBarSwift"
    static let namespace = CodexUsageAnalyzer.SessionEventCache.cacheNamespace

    private static let stateDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR"
    private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"

    private struct CacheState: Codable {
        let usageCacheNamespace: String
        let initializedAt: Date
    }

    static var isCurrentCachePrepared: Bool {
        guard !CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled else { return true }
        guard let state = loadState() else { return false }
        return state.usageCacheNamespace == namespace
    }

    static func markCurrentCachePrepared() {
        guard !CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled,
              let url = stateURL else {
            return
        }
        if loadState()?.usageCacheNamespace == namespace {
            return
        }
        let state = CacheState(usageCacheNamespace: namespace, initializedAt: Date())
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
            cleanOldDiscardableCaches()
        } catch {
            // Cache state only controls the UI hint; failure should not block usage stats.
        }
    }

    static func clearStateForTesting() {
        guard let url = stateURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadState() -> CacheState? {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CacheState.self, from: data)
    }

    private static var stateURL: URL? {
        if let override = ProcessInfo.processInfo.environment[stateDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .appendingPathComponent("cache-state.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("cache-state.json")
    }

    private static func cleanOldDiscardableCaches() {
        guard let cacheRoot = cacheRootURL else {
            return
        }
        let legacySharedRoot = cacheRoot.appendingPathComponent("CodexTokenBar", isDirectory: true)
        for name in [
            "session-token-events-v2.json",
            "session-token-events-v3.json",
            "session-token-events-v4.json",
            "session-token-events-v5.json",
            "session-token-events-v6",
            "session-token-snapshots-v6.json"
        ] {
            try? FileManager.default.removeItem(
                at: legacySharedRoot.appendingPathComponent(name)
            )
        }
        let swiftCacheRoot = cacheRoot.appendingPathComponent(appDirectoryName, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: swiftCacheRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for child in children where child.lastPathComponent != namespace {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static var cacheRootURL: URL? {
        if let override = ProcessInfo.processInfo.environment[cacheDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
