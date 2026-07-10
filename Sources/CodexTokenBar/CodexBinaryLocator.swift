import AppKit
import Foundation

enum CodexApplicationLocator {
    static let bundleIdentifier = "com.openai.codex"

    static func registeredApplicationURLs() -> [URL] {
        var urls: [URL] = []
        if let registered = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            urls.append(registered)
        }

        let runningURLs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .compactMap(\.bundleURL)
            .sorted { $0.path < $1.path }
        urls.append(contentsOf: runningURLs)
        return deduplicated(urls)
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum CodexBinaryLocator {
    static let overrideEnvironmentKey = "CODEX_CLI_PATH"

    static func findExecutable() throws -> String {
        let homeDirectory = NSHomeDirectory()
        let homeApplications = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        return try findExecutable(
            environment: ProcessInfo.processInfo.environment,
            registeredApplicationURLs: CodexApplicationLocator.registeredApplicationURLs(),
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeApplications
            ],
            knownApplicationURLs: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
                homeApplications.appendingPathComponent("ChatGPT.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
                homeApplications.appendingPathComponent("Codex.app", isDirectory: true)
            ],
            knownCLIPaths: [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        )
    }

    static func findExecutable(
        environment: [String: String],
        registeredApplicationURLs: [URL],
        applicationRoots: [URL],
        knownApplicationURLs: [URL],
        knownCLIPaths: [String],
        fileManager: FileManager = .default
    ) throws -> String {
        var candidates: [URL] = []

        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }

        candidates.append(contentsOf: registeredApplicationURLs.map(codexBinaryURL(in:)))
        for root in applicationRoots {
            candidates.append(contentsOf: scannedApplicationBinaryURLs(in: root, fileManager: fileManager))
        }
        candidates.append(contentsOf: knownApplicationURLs.map(codexBinaryURL(in:)))

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex") })
        }
        candidates.append(contentsOf: knownCLIPaths.map { URL(fileURLWithPath: $0) })

        var checked = Set<String>()
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard checked.insert(resolved.path).inserted,
                  isRegularExecutable(resolved, fileManager: fileManager)
            else {
                continue
            }
            return resolved.path
        }
        throw AccountQuotaReaderError.codexBinaryNotFound
    }

    private static func codexBinaryURL(in applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/Resources/codex")
    }

    private static func scannedApplicationBinaryURLs(
        in root: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter { url in
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                else {
                    return false
                }
                return values.isDirectory == true
            }
            .sorted { $0.path < $1.path }
            .map(codexBinaryURL(in:))
    }

    private static func isRegularExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return false
        }
        return true
    }
}
