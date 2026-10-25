import Darwin
import Foundation

/// Incremental directory walk for one root: a directory is listed again only when its own mtime or identity
/// changes (adding, removing or renaming an entry updates the directory's mtime).
///
/// Directories up to `maxDepth` levels below the root are listed (like .NET `MaxRecursionDepth`), so transcripts
/// can sit `maxDepth + 1` levels deep.
struct DirectoryIndex: Sendable {
    /// Hard bound on candidates held in memory; the per-root file limit is applied later, by recency.
    static let maxCandidates = 200_000

    private struct Listing: Sendable {
        var identity: FileIdentity
        var modifiedNs: Int64
        var directories: [String]
        var transcripts: [String]
    }

    let root: String
    let names: TranscriptNames
    let maxDepth: Int
    let maxCandidates: Int
    private var listings: [String: Listing] = [:]

    init(
        root: String,
        names: TranscriptNames = .jsonl,
        maxDepth: Int = TranscriptDiscovery.maxDepth,
        maxCandidates: Int = DirectoryIndex.maxCandidates
    ) {
        self.root = TranscriptDiscovery.normalizedRoot(root)
        self.names = names
        self.maxDepth = maxDepth
        self.maxCandidates = maxCandidates
    }

    /// Paths of every transcript regular file within the limits. Symlinks are never followed below the root.
    mutating func scan() -> [String] {
        var found: [String] = []
        var visited: Set<String> = []
        var pending: [(path: String, depth: Int)] = [(root, 0)]
        while let (directory, depth) = pending.popLast() {
            let info = depth == 0 ? FileStat.stat(directory) : FileStat.lstat(directory)
            guard let info, info.isDirectory else {
                listings[directory] = nil
                continue
            }
            visited.insert(directory)
            let listing: Listing
            if let cached = listings[directory], cached.identity == info.identity, cached.modifiedNs == info.modifiedNs {
                listing = cached
            } else {
                listing = Self.list(directory, info: info, names: names)
                listings[directory] = listing
            }
            if names.acceptsFiles(inDirectoryAtDepth: depth) {
                for path in listing.transcripts {
                    found.append(path)
                    if found.count >= maxCandidates { return found }
                }
            }
            if depth < maxDepth {
                for path in listing.directories where names.descends(into: (path as NSString).lastPathComponent, fromDepth: depth) {
                    pending.append((path, depth + 1))
                }
            }
        }
        if listings.count > visited.count {
            listings = listings.filter { visited.contains($0.key) }
        }
        return found
    }

    private static func list(_ directory: String, info: FileStat, names: TranscriptNames) -> Listing {
        var listing = Listing(identity: info.identity, modifiedNs: info.modifiedNs, directories: [], transcripts: [])
        guard let handle = opendir(directory) else { return listing }
        defer { closedir(handle) }
        while let entry = readdir(handle) {
            guard let name = entryName(entry), name != ".", name != ".." else { continue }
            let path = directory == "/" ? "/" + name : directory + "/" + name
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN, let stat = FileStat.lstat(path) {
                type = stat.isDirectory ? DT_DIR : (stat.isRegularFile ? DT_REG : DT_UNKNOWN)
            }
            if type == DT_DIR {
                listing.directories.append(path)
            } else if type == DT_REG, names.matches(name) {
                listing.transcripts.append(path)
            }
        }
        return listing
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(validatingCString: $0)
            }
        }
    }
}
