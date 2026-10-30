import Darwin
import Foundation

/// Bounded, local-only discovery for the transcript and database formats read by `MultiClientUsageParsers`.
enum MultiClientUsageDiscovery {
    static let maximumFiles = 20_000
    static let maximumVisitedEntries = 200_000
    static let maximumDepth = 6
    private static let maximumClaudeClassificationBytes = 64 * 1_024
    private static let maximumClaudeClassificationCandidates = maximumFiles * 2
    private static let maximumClaudeClassificationTotalBytes = 64 * 1_024 * 1_024

    private struct Candidate {
        var url: URL
        var modifiedNanoseconds: Int64
    }

    private struct ClaudeClassification {
        var client: UsageClient
        var bytesRead: Int
        var wasIncomplete: Bool
    }

    struct Result: Sendable {
        var files: [URL]
        var truncated: Bool
    }

    /// Convenience wrapper for callers that do not need to surface a bounded-discovery notice.
    static func files(client: UsageClient, home: URL, environment: [String: String]) -> [URL] {
        discover(client: client, home: home, environment: environment).files
    }

    /// Returns local transcript files plus an explicit signal whenever a discovery or classification limit was hit.
    static func discover(client: UsageClient, home: URL, environment: [String: String]) -> Result {
        switch client {
        case .claudeCode, .claudeDesktop:
            let config = environment["CLAUDE_CONFIG_DIR"].flatMap(nonEmptyPath)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            return walk(root: config.appendingPathComponent("projects", isDirectory: true), client: client)
        case .deepseek:
            let root = environment["DSH_HOME"].flatMap(nonEmptyPath)
                .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("sessions", isDirectory: true) }
                ?? home.appendingPathComponent(".dsh/sessions", isDirectory: true)
            return walk(root: root, client: client)
        case .gemini:
            let base = environment["GEMINI_CLI_HOME"].flatMap(nonEmptyPath)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home
            let roots = [
                base.appendingPathComponent(".gemini/tmp", isDirectory: true),
                base.appendingPathComponent(".cache/.gemini/tmp", isDirectory: true),
            ]
            return walk(roots: roots, client: client)
        case .opencode:
            let opencodeRoot: URL
            if let configured = environment["OPENCODE_DATA_DIR"].flatMap(nonEmptyPath) {
                let configuredURL = URL(fileURLWithPath: configured)
                opencodeRoot = configuredURL.lastPathComponent == "opencode.db"
                    ? configuredURL.deletingLastPathComponent()
                    : configuredURL
            } else {
                let dataHome = environment["XDG_DATA_HOME"].flatMap(nonEmptyPath)
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? home.appendingPathComponent(".local/share", isDirectory: true)
                opencodeRoot = dataHome.appendingPathComponent("opencode", isDirectory: true)
            }
            let database = opencodeRoot.appendingPathComponent("opencode.db")
            let databaseFiles = isRegularNonSymlink(database) ? [database.standardizedFileURL] : []
            let legacyMessages = walk(
                root: opencodeRoot.appendingPathComponent("storage/message", isDirectory: true),
                client: .opencode
            )
            var result = databaseFiles
            let remainingSlots = max(0, maximumFiles - result.count)
            for file in legacyMessages.files where !result.contains(file) {
                guard result.count < maximumFiles else { break }
                result.append(file)
            }
            let cappedByTotal = legacyMessages.files.count > remainingSlots
            return Result(files: result, truncated: legacyMessages.truncated || cappedByTotal)
        }
    }

    private static func walk(roots: [URL], client: UsageClient) -> Result {
        var found: [Candidate] = []
        var seenRoots: Set<String> = []
        var remainingEntries = maximumVisitedEntries
        var truncated = false
        for root in roots {
            guard remainingEntries > 0,
                  seenRoots.insert(root.resolvingSymlinksInPath().standardizedFileURL.path).inserted,
                  isDirectoryNonSymlink(root.resolvingSymlinksInPath())
            else { continue }
            let entryBudget = remainingEntries
            let result = walk(root: root, client: client, entryBudget: entryBudget)
            found.append(contentsOf: result.files)
            remainingEntries -= result.visitedEntries
            if result.truncated { truncated = true }
        }
        if remainingEntries == 0 { truncated = true }
        let selected = mostRecent(found, client: client)
        return Result(files: selected.files, truncated: truncated || selected.truncated)
    }

    private static func walk(root: URL, client: UsageClient) -> Result {
        let walked = walk(root: root, client: client, entryBudget: maximumVisitedEntries)
        let selected = mostRecent(walked.files, client: client)
        return Result(
            files: selected.files,
            truncated: selected.truncated || walked.truncated
        )
    }

    private static func walk(
        root: URL,
        client: UsageClient,
        entryBudget: Int
    ) -> (files: [Candidate], visitedEntries: Int, truncated: Bool) {
        guard entryBudget > 0 else { return ([], 0, true) }
        // Follow the selected root only. Keep logical paths for source/checkpoint identity;
        // child links remain excluded by fileKind and the directory enumerator.
        let physicalRoot = root.resolvingSymlinksInPath()
        guard isDirectoryNonSymlink(physicalRoot) else { return ([], 0, false) }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: physicalRoot.path) else { return ([], 0, true) }
        var visitedEntries = 0
        var files: [Candidate] = []

        while visitedEntries < entryBudget,
              let relativePath = enumerator.nextObject() as? String {
            visitedEntries += 1
            let components = relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            let child = root.appendingPathComponent(relativePath)
            let hiddenPath = components.contains { $0.hasPrefix(".") }
            let kind = fileKind(child)
            if kind == .directory {
                guard !hiddenPath,
                      components.count < maximumDepth,
                      shouldDescend(client: client, name: name, depth: components.count - 1)
                else {
                    enumerator.skipDescendants()
                    continue
                }
            } else if !hiddenPath, kind == .regularFile, matches(client: client, name: name, components: components) {
                files.append(Candidate(url: child.standardizedFileURL, modifiedNanoseconds: modificationNanoseconds(child)))
            }
        }
        // One look-ahead distinguishes a directory with exactly `entryBudget` entries from one whose
        // history was cut short. It remains lazy and does not materialize a whole directory listing.
        let truncated = visitedEntries == entryBudget && enumerator.nextObject() != nil
        return (files, visitedEntries, truncated)
    }

    private static func mostRecent(_ candidates: [Candidate], client: UsageClient) -> Result {
        let sorted = candidates.sorted {
            if $0.modifiedNanoseconds != $1.modifiedNanoseconds {
                return $0.modifiedNanoseconds > $1.modifiedNanoseconds
            }
            return $0.url.path < $1.url.path
        }
        guard client == .claudeCode || client == .claudeDesktop else {
            return Result(files: Array(sorted.prefix(maximumFiles).map(\.url)), truncated: sorted.count > maximumFiles)
        }

        var selected: [URL] = []
        var remainingClassificationBytes = maximumClaudeClassificationTotalBytes
        var truncated = sorted.count > maximumClaudeClassificationCandidates || sorted.count > maximumFiles
        for candidate in sorted.prefix(maximumClaudeClassificationCandidates) {
            guard remainingClassificationBytes > 0 else {
                truncated = true
                break
            }
            let classification = claudeTranscriptClient(
                candidate.url,
                byteLimit: min(maximumClaudeClassificationBytes, remainingClassificationBytes)
            )
            remainingClassificationBytes -= classification.bytesRead
            if classification.wasIncomplete { truncated = true }
            if classification.client == client {
                selected.append(candidate.url)
                if selected.count == maximumFiles {
                    truncated = truncated || sorted.count > selected.count
                    break
                }
            }
        }
        return Result(files: selected, truncated: truncated)
    }

    /// Claude Code and Claude Desktop share the same directory tree. Classify a file using its first
    /// entrypoint-bearing record so records in later incremental chunks can omit entrypoint.
    private static func claudeTranscriptClient(_ url: URL, byteLimit: Int) -> ClaudeClassification {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ClaudeClassification(client: .claudeCode, bytesRead: 0, wasIncomplete: true)
        }
        defer { try? handle.close() }
        var remaining = byteLimit
        var bytesRead = 0
        var buffered = Data()
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(4 * 1_024, remaining)),
                  !chunk.isEmpty
            else { break }
            remaining -= chunk.count
            bytesRead += chunk.count
            buffered.append(chunk)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = Data(buffered.prefix(upTo: newline))
                buffered.removeSubrange(...newline)
                if let source = claudeSource(inCompleteLine: line) {
                    return ClaudeClassification(client: source, bytesRead: bytesRead, wasIncomplete: false)
                }
            }
        }
        return ClaudeClassification(
            client: .claudeCode,
            bytesRead: bytesRead,
            wasIncomplete: remaining == 0
        )
    }

    private static func claudeSource(inCompleteLine rawLine: Data) -> UsageClient? {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let entrypoint = object["entrypoint"] as? String,
              !entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return entrypoint.hasPrefix("claude-desktop") ? .claudeDesktop : .claudeCode
    }

    private enum FileKind: Equatable {
        case directory
        case regularFile
        case other
    }

    private static func fileKind(_ url: URL) -> FileKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: return .other
        }
    }

    private static func isDirectoryNonSymlink(_ url: URL) -> Bool {
        fileKind(url) == .directory
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        fileKind(url) == .regularFile
    }

    private static func modificationNanoseconds(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return Int64.min }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    private static func shouldDescend(client: UsageClient, name: String, depth: Int) -> Bool {
        switch client {
        case .claudeCode, .claudeDesktop, .deepseek:
            return depth < maximumDepth
        case .gemini:
            switch depth {
            case 0, 2: return true
            case 1: return name == "chats"
            default: return false
            }
        case .opencode:
            return depth < maximumDepth
        }
    }

    private static func matches(client: UsageClient, name: String, components: [String]) -> Bool {
        switch client {
        case .claudeCode, .claudeDesktop:
            return name.hasSuffix(".jsonl")
        case .deepseek:
            let suffix = name.hasSuffix(".jsonl.zstd") ? ".jsonl.zstd" : ".jsonl"
            guard name.hasPrefix("session.v"), name.hasSuffix(suffix) else { return false }
            let version = name.dropFirst("session.v".count).dropLast(suffix.count)
            return !version.isEmpty && version.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        case .gemini:
            guard name.hasSuffix(".jsonl") || name.hasSuffix(".json"),
                  components.count == 3 || components.count == 4,
                  components[1] == "chats"
            else { return false }
            return true
        case .opencode:
            return name.hasSuffix(".json")
        }
    }

    private static func nonEmptyPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }
}
