import Foundation

/// SwiftPM's generated accessor embeds the build machine's path and its app
/// layout assumptions vary across toolchains. Installed apps always resolve
/// their own signed Resources directory before considering the CLI accessor.
enum AppResources {
    static let bundle: Bundle? = resolve(
        applicationURL: Bundle.main.bundleURL,
        resourceURL: Bundle.main.resourceURL
    ) { Bundle.module }

    static func resolve(applicationURL: URL, resourceURL: URL?, packageBundle: () -> Bundle) -> Bundle? {
        let name = "CodexTokenBar_CodexTokenBar.bundle"
        let candidates = [resourceURL?.appendingPathComponent(name), applicationURL.appendingPathComponent(name)]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Missing installed resources must produce a recoverable error rather
        // than fatalError in SwiftPM's accessor or fall back to a developer tree.
        if applicationURL.pathExtension == "app" { return nil }
        return packageBundle()
    }

    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        bundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    /// Used by the packaged executable before SwiftUI, preferences, databases,
    /// readers or network owners are initialized. Works from any current cwd.
    static func verifyPackagedResources() throws {
        let paths = [
            "codex-ledger-schema.sql", "activity-speed-schema.sql",
            "standard-api-price-history.json", "o200k_base.tiktoken",
            "ModelTrace/fingerprint-core.js", "ModelTrace/unified_bank.json",
            "ModelTrace/scoring-fixtures.json", "SpeedLeaderboard/leaderboard.mp4",
            "SpeedLeaderboard/poster.jpg"
        ]
        guard let root = bundle?.resourceURL else { throw Failure.missing("resource bundle") }
        for path in paths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw Failure.missing(path) }
        }
    }

    enum Failure: Error { case missing(String) }
}
