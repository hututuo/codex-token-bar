import Darwin
import Foundation

/// Bounded, local-only discovery for the transcript and database formats read by `MultiClientUsageParsers`.
enum MultiClientUsageDiscovery {
    static let maximumFiles = 20_000
    static let maximumVisitedEntries = 200_000
    static let maximumDepth = 6
    private static let maximumClaudeClassificationBytes = ClaudeTranscriptClassification.maximumBytes
    private static let maximumClaudeClassificationCandidates = maximumFiles * 2
    private static let maximumClaudeClassificationTotalBytes = 64 * 1_024 * 1_024

    private struct Candidate {
        var url: URL
        var modifiedNanoseconds: Int64
    }

    private struct ClaudeClassification {
        var client: UsageClient?
        var bytesRead: Int
        var wasIncomplete: Bool
    }

    struct Result: Sendable {
        var files: [URL]
        var truncated: Bool
    }

    struct ClaudePairResult: Sendable {
        var code: Result
        var desktop: Result
        /// Actual classifier calls and bytes read, excluding reuse by the other client.
        var classificationCount: Int
        var classificationBytesRead: Int
    }

    private struct ClaudeSelection {
        var files: [URL] = []
        var remainingClassificationBytes = MultiClientUsageDiscovery.maximumClaudeClassificationTotalBytes
        var truncated: Bool
        var finished = false
    }

    /// Convenience wrapper for callers that do not need to surface a bounded-discovery notice.
    static func files(client: UsageClient, home: URL, environment: [String: String]) -> [URL] {
        discover(client: client, home: home, environment: environment).files
    }

    /// Returns local transcript files plus an explicit signal whenever a discovery or classification limit was hit.
    static func discover(
        client: UsageClient,
        home: URL,
        environment: [String: String],
        claudeCheckpointOwners: [String: Set<UsageClient>] = [:]
    ) -> Result {
        switch client {
        case .antigravity:
            return AntigravityUsageSource.discover(home: home)
        case .claudeCode, .claudeDesktop:
            let roots = claudeProjectRoots(home: home, environment: environment)
            let walked = walkCandidates(roots: roots.paths, client: client)
            let selected = mostRecent(walked.files, client: client, claudeCheckpointOwners: claudeCheckpointOwners)
            let discovered = Result(files: selected.files, truncated: walked.truncated || selected.truncated)
            return Result(files: discovered.files, truncated: discovered.truncated || roots.incomplete)
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

    /// Automatic Claude sources share one scan's traversal, ordering and classification reads.
    /// Each client still consumes its own classification and file-selection budgets.
    static func discoverClaudePair(
        home: URL,
        environment: [String: String],
        claudeCheckpointOwners: [String: Set<UsageClient>] = [:]
    ) -> ClaudePairResult {
        let roots = claudeProjectRoots(home: home, environment: environment)
        // Both Claude clients have identical directory and candidate-file predicates.
        let walked = walkCandidates(roots: roots.paths, client: .claudeCode)
        let selected = selectClaude(
            mostRecentFirst(walked.files),
            clients: [.claudeCode, .claudeDesktop],
            claudeCheckpointOwners: claudeCheckpointOwners
        )
        var code = selected.results[0]
        var desktop = selected.results[1]
        code.truncated = code.truncated || walked.truncated || roots.incomplete
        desktop.truncated = desktop.truncated || walked.truncated || roots.incomplete
        return ClaudePairResult(
            code: code, desktop: desktop,
            classificationCount: selected.classificationCount,
            classificationBytesRead: selected.classificationBytesRead
        )
    }

    /// The launcher's v1 registry contains IDs/labels only. Derive known transcript paths;
    /// never crawl account storage, Desktop profiles, settings or authentication files.
    static func claudeProjectRoots(home: URL, environment: [String: String]) -> (paths: [URL], incomplete: Bool) {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap(nonEmptyPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        var paths = [config.appendingPathComponent("projects", isDirectory: true)]
        let accounts = home.appendingPathComponent(".local/share/claude-adapter/accounts", isDirectory: true)
        let registry = accounts.appendingPathComponent("registry.json")
        var registryInfo = stat()
        guard lstat(registry.path, &registryInfo) == 0 else { return (paths, errno != ENOENT) }
        guard isDirectoryNonSymlink(accounts), isRegularNonSymlink(registry),
              let handle = try? FileHandle(forReadingFrom: registry) else { return (paths, true) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_769), data.count <= 32_768,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber,
              String(cString: version.objCType) != "c", version.stringValue == "1",
              let rows = object["accounts"] as? [[String: Any]], (1...16).contains(rows.count)
        else { return (paths, true) }
        var identifiers: Set<String> = []
        var registered: [URL] = []
        var incomplete = false
        for row in rows {
            guard let id = row["id"] as? String,
                  id == "existing" || (id.utf8.count == 32 && id.utf8.allSatisfy({
                      ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
                  })), identifiers.insert(id).inserted else { return (paths, true) }
            if id == "existing" {
                registered.append(home.appendingPathComponent(".claude-official-guarded/projects", isDirectory: true))
            } else {
                let account = accounts.appendingPathComponent(id, isDirectory: true)
                let code = account.appendingPathComponent("code", isDirectory: true)
                // Account ancestors are not user-selected roots: reject aliases into other storage.
                guard isDirectoryNonSymlink(account), isDirectoryNonSymlink(code) else {
                    if FileManager.default.fileExists(atPath: account.path) { incomplete = true }
                    continue
                }
                registered.append(code.appendingPathComponent("projects", isDirectory: true))
            }
        }
        guard identifiers.contains("existing") else { return (paths, true) }
        paths.append(contentsOf: registered)
        return (paths, incomplete)
    }

    private static func walk(roots: [URL], client: UsageClient) -> Result {
        let walked = walkCandidates(roots: roots, client: client)
        let selected = mostRecent(walked.files, client: client)
        return Result(files: selected.files, truncated: walked.truncated || selected.truncated)
    }

    private static func walkCandidates(roots: [URL], client: UsageClient) -> (files: [Candidate], truncated: Bool) {
        var found: [Candidate] = []
        var seenRoots: Set<String> = []
        var seenFiles: Set<String> = []
        var remainingEntries = maximumVisitedEntries
        var truncated = false
        for root in roots {
            guard remainingEntries > 0,
                  seenRoots.insert(root.resolvingSymlinksInPath().standardizedFileURL.path).inserted,
                  isDirectoryNonSymlink(root.resolvingSymlinksInPath())
            else { continue }
            let entryBudget = remainingEntries
            let result = walk(root: root, client: client, entryBudget: entryBudget)
            for candidate in result.files where seenFiles.insert(candidate.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
                found.append(candidate)
            }
            remainingEntries -= result.visitedEntries
            if result.truncated { truncated = true }
        }
        if remainingEntries == 0 { truncated = true }
        return (found, truncated)
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

    private static func mostRecentFirst(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted {
            if $0.modifiedNanoseconds != $1.modifiedNanoseconds {
                return $0.modifiedNanoseconds > $1.modifiedNanoseconds
            }
            return $0.url.path < $1.url.path
        }
    }

    private static func mostRecent(
        _ candidates: [Candidate],
        client: UsageClient,
        claudeCheckpointOwners: [String: Set<UsageClient>] = [:]
    ) -> Result {
        let sorted = mostRecentFirst(candidates)
        guard client == .claudeCode || client == .claudeDesktop else {
            return Result(files: Array(sorted.prefix(maximumFiles).map(\.url)), truncated: sorted.count > maximumFiles)
        }
        return selectClaude(sorted, clients: [client], claudeCheckpointOwners: claudeCheckpointOwners).results[0]
    }

    private static func selectClaude(
        _ sorted: [Candidate],
        clients: [UsageClient],
        claudeCheckpointOwners: [String: Set<UsageClient>] = [:]
    ) -> (results: [Result], classificationCount: Int, classificationBytesRead: Int) {
        var selections = clients.map { _ in
            ClaudeSelection(truncated: sorted.count > maximumClaudeClassificationCandidates || sorted.count > maximumFiles)
        }
        var classificationCount = 0
        var classificationBytesRead = 0
        for candidate in sorted.prefix(maximumClaudeClassificationCandidates) {
            if selections.allSatisfy(\.finished) { break }
            let owners = claudeCheckpointOwners[MultiClientUsageLedger.sourceKey(for: candidate.url)] ?? []
            if !owners.isEmpty {
                // Existing ledger ownership wins until provenance supports a safe
                // cross-client reconciliation. Preserve all extant owners and
                // signal any newly requested namespace that was withheld.
                for index in selections.indices where !selections[index].finished {
                    if owners.contains(clients[index]) {
                        selections[index].files.append(candidate.url)
                        if selections[index].files.count == maximumFiles {
                            selections[index].truncated = selections[index].truncated || sorted.count > selections[index].files.count
                            selections[index].finished = true
                        }
                    } else {
                        selections[index].truncated = true
                    }
                }
                continue
            }
            // Reuse only this candidate and an identical requested read bound. No file state
            // survives the scan; appends and rewrites are classified again on the next scan.
            var cached: (byteLimit: Int, classification: ClaudeClassification)?
            for index in selections.indices where !selections[index].finished {
                guard selections[index].remainingClassificationBytes > 0 else {
                    selections[index].truncated = true
                    selections[index].finished = true
                    continue
                }
                let byteLimit = min(maximumClaudeClassificationBytes, selections[index].remainingClassificationBytes)
                let classification: ClaudeClassification
                if let cached, cached.byteLimit == byteLimit {
                    classification = cached.classification
                } else {
                    classification = claudeTranscriptClient(candidate.url, byteLimit: byteLimit)
                    classificationCount += 1
                    classificationBytesRead += classification.bytesRead
                    cached = (byteLimit, classification)
                }
                selections[index].remainingClassificationBytes -= classification.bytesRead
                if classification.wasIncomplete { selections[index].truncated = true }
                if classification.client == clients[index] {
                    selections[index].files.append(candidate.url)
                    if selections[index].files.count == maximumFiles {
                        selections[index].truncated = selections[index].truncated || sorted.count > selections[index].files.count
                        selections[index].finished = true
                    }
                }
            }
        }
        return (
            selections.map { Result(files: $0.files, truncated: $0.truncated) },
            classificationCount, classificationBytesRead
        )
    }

    /// Claude Code and Claude Desktop share the same directory tree. Only complete
    /// entrypoint-bearing records are explicit evidence; incomplete reads select neither client.
    private static func claudeTranscriptClient(_ url: URL, byteLimit: Int) -> ClaudeClassification {
        do {
            let result = try ClaudeTranscriptClassification.classify(url: url, byteLimit: byteLimit)
            let client: UsageClient?
            switch result.evidence {
            case .explicit(let value, _): client = value
            case .legacyCLI: client = .claudeCode
            case .incomplete: client = nil
            }
            return ClaudeClassification(
                client: client,
                bytesRead: result.bytesRead,
                wasIncomplete: client == nil
            )
        } catch {
            return ClaudeClassification(client: nil, bytesRead: 0, wasIncomplete: true)
        }
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
        case .antigravity: return false
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
        case .antigravity: return components.count == 1 && AntigravityUsageSource.isConversation(URL(fileURLWithPath: name))
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
