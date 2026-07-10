import AppKit
import Foundation

struct CodexApplicationCandidate {
    let url: URL
    let bundleIdentifier: String?
}

enum CodexApplicationLocator {
    static let bundleIdentifier = "com.openai.codex"

    static func registeredApplications() -> [CodexApplicationCandidate] {
        var candidates: [CodexApplicationCandidate] = []
        if let registered = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            candidates.append(CodexApplicationCandidate(
                url: registered,
                bundleIdentifier: bundleIdentifier
            ))
        }

        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .compactMap { application -> CodexApplicationCandidate? in
                guard let url = application.bundleURL else { return nil }
                return CodexApplicationCandidate(
                    url: url,
                    bundleIdentifier: application.bundleIdentifier
                )
            }
            .sorted { $0.url.path < $1.url.path }
        candidates.append(contentsOf: runningApplications)
        return deduplicated(candidates)
    }

    private static func deduplicated(
        _ candidates: [CodexApplicationCandidate]
    ) -> [CodexApplicationCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
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
            registeredApplications: CodexApplicationLocator.registeredApplications(),
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
        registeredApplications: [CodexApplicationCandidate],
        applicationRoots: [URL],
        knownApplicationURLs: [URL],
        knownCLIPaths: [String],
        fileManager: FileManager = .default
    ) throws -> String {
        var candidates: [URL] = []

        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }

        candidates.append(contentsOf: registeredApplications
            .filter { $0.bundleIdentifier == CodexApplicationLocator.bundleIdentifier }
            .map { codexBinaryURL(in: $0.url) })
        for root in applicationRoots {
            candidates.append(contentsOf: scannedApplicationBinaryURLs(in: root, fileManager: fileManager))
        }
        candidates.append(contentsOf: knownApplicationURLs
            .filter {
                applicationBundleIdentifier(at: $0, fileManager: fileManager)
                    == CodexApplicationLocator.bundleIdentifier
            }
            .map(codexBinaryURL(in:)))

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
                    && applicationBundleIdentifier(at: url, fileManager: fileManager)
                        == CodexApplicationLocator.bundleIdentifier
            }
            .sorted { $0.path < $1.path }
            .map(codexBinaryURL(in:))
    }

    private static func applicationBundleIdentifier(
        at applicationURL: URL,
        fileManager: FileManager
    ) -> String? {
        let infoPlist = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: infoPlist.path),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = propertyList as? [String: Any]
        else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
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
