import Foundation

/// One entry of a zip archive's central directory.
public struct ZipEntry: Sendable, Equatable {
    public let path: String
    public let uncompressedSize: UInt64
    public let isSymbolicLink: Bool

    public init(path: String, uncompressedSize: UInt64 = 0, isSymbolicLink: Bool = false) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.isSymbolicLink = isSymbolicLink
    }

    public var isDirectory: Bool { path.hasSuffix("/") }
}

public enum ZipDirectoryError: Error, Equatable, Sendable {
    case malformed
    /// Multi-disk or ZIP64 archives; update packages never need them.
    case unsupported
}

/// Reads the central directory of a zip archive without extracting anything, so entry names can be vetted first.
public enum ZipDirectory {
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let entrySignature: UInt32 = 0x0201_4B50
    private static let endRecordSize = 22
    private static let entryHeaderSize = 46
    private static let maxCommentSize = 0xFFFF
    private static let maxDirectorySize = 64 << 20

    public static func entries(of url: URL) throws -> [ZipEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= UInt64(endRecordSize) else { throw ZipDirectoryError.malformed }
        let tailSize = min(fileSize, UInt64(endRecordSize + maxCommentSize))
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        let end = try endRecord(in: tail)
        guard UInt64(end.directoryOffset) + UInt64(end.directorySize) <= fileSize - tailSize + UInt64(end.position) else {
            throw ZipDirectoryError.malformed
        }
        try handle.seek(toOffset: UInt64(end.directoryOffset))
        let directory = try handle.read(upToCount: Int(end.directorySize)) ?? Data()
        return try parseEntries(directory, count: end.entryCount)
    }

    /// Parses a complete archive held in memory.
    public static func entries(in archive: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](archive)
        let end = try endRecord(in: archive)
        let start = Int(end.directoryOffset)
        let stop = start + Int(end.directorySize)
        guard stop <= end.position, start <= stop else { throw ZipDirectoryError.malformed }
        return try parseEntries(Data(bytes[start..<stop]), count: end.entryCount)
    }

    private struct EndRecord {
        let position: Int
        let entryCount: Int
        let directorySize: UInt32
        let directoryOffset: UInt32
    }

    private static func endRecord(in data: Data) throws -> EndRecord {
        let bytes = [UInt8](data)
        guard bytes.count >= endRecordSize else { throw ZipDirectoryError.malformed }
        var position = bytes.count - endRecordSize
        let lowest = max(0, bytes.count - endRecordSize - maxCommentSize)
        while position >= lowest {
            if read32(bytes, position) == endSignature,
               Int(read16(bytes, position + 20)) == bytes.count - position - endRecordSize {
                let disk = read16(bytes, position + 4)
                let directoryDisk = read16(bytes, position + 6)
                let entriesOnDisk = read16(bytes, position + 8)
                let entries = read16(bytes, position + 10)
                let size = read32(bytes, position + 12)
                let offset = read32(bytes, position + 16)
                guard disk == 0, directoryDisk == 0, entriesOnDisk == entries else { throw ZipDirectoryError.unsupported }
                guard entries != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw ZipDirectoryError.unsupported }
                guard Int(size) <= maxDirectorySize else { throw ZipDirectoryError.malformed }
                return EndRecord(position: position, entryCount: Int(entries), directorySize: size, directoryOffset: offset)
            }
            position -= 1
        }
        throw ZipDirectoryError.malformed
    }

    private static func parseEntries(_ data: Data, count: Int) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)
        var cursor = 0
        for _ in 0..<count {
            guard cursor + entryHeaderSize <= bytes.count, read32(bytes, cursor) == entrySignature else {
                throw ZipDirectoryError.malformed
            }
            let madeBy = read16(bytes, cursor + 4)
            let uncompressed = read32(bytes, cursor + 24)
            let nameLength = Int(read16(bytes, cursor + 28))
            let extraLength = Int(read16(bytes, cursor + 30))
            let commentLength = Int(read16(bytes, cursor + 32))
            let diskStart = read16(bytes, cursor + 34)
            let external = read32(bytes, cursor + 38)
            let localOffset = read32(bytes, cursor + 42)
            guard diskStart == 0, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipDirectoryError.unsupported
            }
            let nameStart = cursor + entryHeaderSize
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= bytes.count, nameLength > 0 else { throw ZipDirectoryError.malformed }
            // ditto writes UTF-8 names without setting the UTF-8 flag (bit 11), so names are always read as UTF-8.
            guard let path = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw ZipDirectoryError.malformed
            }
            let isUnix = madeBy >> 8 == 3
            let mode = external >> 16
            let isLink = isUnix && mode & 0o170000 == 0o120000
            entries.append(ZipEntry(path: path, uncompressedSize: UInt64(uncompressed), isSymbolicLink: isLink))
            cursor = next
        }
        return entries
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

public enum ArchiveLayoutError: Error, Equatable, Sendable {
    case unsafePath(String)
    case outsideRoot(String)
    case throughSymbolicLink(String)
    case tooLarge
    case empty
}

/// Checks that extracting an archive can only create files inside one top-level folder (UPDATES section 5.3).
public enum ArchiveLayout {
    public static let maxEntries = 20_000
    public static let maxExpandedSize: UInt64 = 1 << 30

    /// A relative path without `..`, empty or `.` components, backslashes or control characters.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\\" || $0.value == 0x7F }) else {
            return false
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func validate(_ entries: [ZipEntry], root: String) throws {
        guard !entries.isEmpty else { throw ArchiveLayoutError.empty }
        guard entries.count <= maxEntries else { throw ArchiveLayoutError.tooLarge }
        var expanded: UInt64 = 0
        var links: [String] = []
        for entry in entries {
            guard isSafe(entry.path) else { throw ArchiveLayoutError.unsafePath(entry.path) }
            guard entry.path == root + "/" || entry.path.hasPrefix(root + "/") else {
                throw ArchiveLayoutError.outsideRoot(entry.path)
            }
            let (sum, overflow) = expanded.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maxExpandedSize else { throw ArchiveLayoutError.tooLarge }
            expanded = sum
            if entry.isSymbolicLink {
                // A symlink named "link/" would let "link/x" slip past the nesting check below.
                guard !entry.isDirectory else { throw ArchiveLayoutError.unsafePath(entry.path) }
                links.append(entry.path)
            }
        }
        // APFS and HFS+ compare names case- and normalization-insensitively, so "Link/x" also goes through "link".
        guard !links.isEmpty else { return }
        let prefixes = Set(links.map { folded($0) + "/" })
        for entry in entries {
            let path = folded(entry.path)
            var index = path.startIndex
            while let slash = path[index...].firstIndex(of: "/") {
                index = path.index(after: slash)
                if prefixes.contains(String(path[..<index])) {
                    throw ArchiveLayoutError.throughSymbolicLink(entry.path)
                }
            }
        }
    }

    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
