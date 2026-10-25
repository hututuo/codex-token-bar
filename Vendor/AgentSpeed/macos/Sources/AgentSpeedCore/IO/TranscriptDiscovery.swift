import Darwin
import Foundation

struct DiscoveredFile: Equatable, Sendable {
    var path: String
    var stat: FileStat
}

/// Which file names under a root are transcripts (METRICS 2).
enum TranscriptNames: Sendable {
    /// `*.jsonl`
    case jsonl
    /// `*.jsonl` or compressed `*.jsonl.zst` (Codex, METRICS 5.3).
    case codexSession
    /// `session.v<N>.jsonl` or `session.v<N>.jsonl.zstd` (DeepSeek Harness).
    case dshSession
    /// `*.jsonl` or legacy `*.json`, only at `<project>/chats/<file>` and `<project>/chats/<dir>/<file>` (Gemini CLI).
    case geminiSession
    /// `*.jsonl` at least one folder below the root; names starting with `.` are skipped, files and folders (omp).
    case ompSession
    /// `<uuid>.db` directly in a `conversations` folder (Antigravity).
    case antigravityDatabase
    /// `*.jsonl` not starting with `.`, only at `<slug>/<file>` and `<slug>/<dir>/subagents/<file>`; `<slug>` and
    /// `<dir>` do not start with `.` and `<slug>` is not `cloud` (WorkBuddy).
    case workbuddySession
    case kimiSession
    case grokBuildSession

    func matches(_ name: String) -> Bool {
        switch self {
        case .kimiSession: return name == "wire.jsonl"
        case .grokBuildSession: return name == "updates.jsonl"
        case .jsonl:
            return name.hasSuffix(".jsonl")
        case .codexSession:
            return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
        case .geminiSession:
            return name.hasSuffix(".jsonl") || name.hasSuffix(".json")
        case .ompSession, .workbuddySession:
            return name.hasSuffix(".jsonl") && !name.hasPrefix(".")
        case .antigravityDatabase:
            return Self.isConversationDatabase(name)
        case .dshSession:
            let prefix = "session.v"
            guard name.hasPrefix(prefix) else { return false }
            let rest = name.utf8.dropFirst(prefix.utf8.count)
            let digits = rest.prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
            guard !digits.isEmpty else { return false }
            let suffix = rest.dropFirst(digits.count)
            return suffix.elementsEqual(".jsonl".utf8) || suffix.elementsEqual(".jsonl.zstd".utf8)
        }
    }

    /// Whether a directory listed at `depth` (the root is 0) may hold transcripts.
    func acceptsFiles(inDirectoryAtDepth depth: Int) -> Bool {
        switch self {
        case .geminiSession: depth == 2 || depth == 3
        case .ompSession: depth >= 1
        case .antigravityDatabase: depth == 0
        case .workbuddySession: depth == 1 || depth == 3
        case .kimiSession: depth == 4
        case .grokBuildSession: depth == 2
        case .jsonl, .codexSession, .dshSession: true
        }
    }

    /// Whether the walk descends into the directory `name` found at `depth`.
    func descends(into name: String, fromDepth depth: Int) -> Bool {
        switch self {
        case .geminiSession:
            switch depth {
            case 0, 2: return true
            case 1: return name == "chats"
            default: return false
            }
        case .ompSession:
            return !name.hasPrefix(".")
        case .antigravityDatabase:
            return false
        case .workbuddySession:
            switch depth {
            case 0: return !name.hasPrefix(".") && name != "cloud"
            case 1: return !name.hasPrefix(".")
            case 2: return name == "subagents"
            default: return false
            }
        case .kimiSession:
            return depth < 4 && (depth != 2 || name == "agents") && !name.hasPrefix(".")
        case .grokBuildSession:
            return depth < 2 && !name.hasPrefix(".")
        case .jsonl, .codexSession, .dshSession:
            return true
        }
    }

    /// Whether a path relative to the root (its components) can name a transcript.
    func accepts(relativeComponents components: [Substring]) -> Bool {
        guard let name = components.last, matches(String(name)) else { return false }
        switch self {
        case .geminiSession:
            return (components.count == 3 || components.count == 4) && components[1] == "chats"
        case .ompSession:
            return components.count >= 2 && components.count <= TranscriptDiscovery.maxDepth + 1
                && !components.contains { $0.hasPrefix(".") }
        case .antigravityDatabase:
            return components.count == 1
        case .workbuddySession:
            let slug = components[0]
            guard !slug.hasPrefix("."), slug != "cloud" else { return false }
            return components.count == 2
                || (components.count == 4 && components[2] == "subagents" && !components[1].hasPrefix("."))
        case .kimiSession:
            return components.count == 5 && components[2] == "agents" && !components.contains { $0.hasPrefix(".") }
        case .grokBuildSession:
            return components.count == 3 && !components.contains { $0.hasPrefix(".") }
        case .jsonl, .codexSession, .dshSession:
            return components.count <= TranscriptDiscovery.maxDepth + 1
        }
    }

    /// 8-4-4-4-12 hexadecimal digits (any case) followed by `.db`.
    static func isConversationDatabase(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 39, bytes.suffix(3).elementsEqual(".db".utf8) else { return false }
        for (index, byte) in bytes.prefix(36).enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
                guard isHex else { return false }
            }
        }
        return true
    }
}

/// Finds transcript files under a root (METRICS 2): `*.jsonl` (DeepSeek: `session.v<N>.jsonl(.zstd)`), depth
/// limit 6, no symlinks, at most 20 000 files per root (the most recently modified ones).
enum TranscriptDiscovery {
    static let maxDepth = 6
    static let maxFiles = 20_000

    /// Removes trailing slashes so agent ids are stable.
    static func normalizedRoot(_ path: String) -> String {
        var root = path
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// True when the root exists, is a directory and can be listed.
    static func isAvailable(root: String) -> Bool {
        guard let info = FileStat.stat(root), info.isDirectory else { return false }
        return access(root, R_OK | X_OK) == 0
    }

    static func enumerate(
        root: String,
        names: TranscriptNames = .jsonl,
        maxDepth: Int = maxDepth,
        maxFiles: Int = maxFiles
    ) -> [DiscoveredFile] {
        var index = DirectoryIndex(root: root, names: names, maxDepth: maxDepth)
        return mostRecent(files(at: index.scan()), limit: maxFiles)
    }

    /// Keeps the `limit` most recently modified files.
    static func mostRecent(_ files: [DiscoveredFile], limit: Int = maxFiles) -> [DiscoveredFile] {
        guard files.count > limit else { return files }
        return Array(files.sorted { lhs, rhs in
            lhs.stat.modifiedNs != rhs.stat.modifiedNs ? lhs.stat.modifiedNs > rhs.stat.modifiedNs : lhs.path < rhs.path
        }.prefix(limit))
    }

    /// Stats candidate paths, keeping regular files only (an Antigravity database's time includes its `-wal`).
    static func files(at paths: [String], family: TranscriptFamily? = nil) -> [DiscoveredFile] {
        paths.compactMap { path in
            let stat = family.map { $0.stat(path) } ?? FileStat.lstat(path)
            guard let stat, stat.isRegularFile else { return nil }
            return DiscoveredFile(path: path, stat: stat)
        }
    }

    /// Startup reading order (METRICS 5): modification time ascending, then ordinal path comparison.
    /// Times compare at 100 ns resolution and paths by UTF-16 code units, matching .NET ordering.
    static func startupOrder(_ lhs: DiscoveredFile, _ rhs: DiscoveredFile) -> Bool {
        let lhsTicks = lhs.stat.modifiedNs / 100
        let rhsTicks = rhs.stat.modifiedNs / 100
        if lhsTicks != rhsTicks { return lhsTicks < rhsTicks }
        return lhs.path.utf16.lexicographicallyPrecedes(rhs.path.utf16)
    }
}
