import Darwin
import Foundation

/// Device and inode of a file; a change means the path now names a different file.
struct FileIdentity: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
}

/// The subset of `stat` the reader needs.
struct FileStat: Equatable, Sendable {
    var identity: FileIdentity
    var size: Int64
    var modifiedNs: Int64
    var isRegularFile: Bool
    var isDirectory: Bool

    var modifiedMs: Int64 { modifiedNs / 1_000_000 }

    init(identity: FileIdentity, size: Int64, modifiedNs: Int64, isRegularFile: Bool, isDirectory: Bool = false) {
        self.identity = identity
        self.size = size
        self.modifiedNs = modifiedNs
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
    }

    private init(_ info: Darwin.stat) {
        let type = info.st_mode & S_IFMT
        self.init(
            identity: FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            modifiedNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            isRegularFile: type == S_IFREG,
            isDirectory: type == S_IFDIR
        )
    }

    /// Stats a path without following a final symlink.
    static func lstat(_ path: String) -> FileStat? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileStat(info)
    }

    /// Stats a path, following symlinks (used for configured roots only).
    static func stat(_ path: String) -> FileStat? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { return nil }
        return FileStat(info)
    }

    /// An Antigravity conversation database: the `.db` with its `-wal` folded in, size the sum and modification time
    /// the newer of the two (METRICS 5.4, 8). Nil unless the `.db` is a regular file.
    static func databaseStat(_ path: String) -> FileStat? {
        guard var stat = lstat(path), stat.isRegularFile else { return nil }
        if let wal = lstat(path + "-wal"), wal.isRegularFile {
            stat.size += wal.size
            stat.modifiedNs = max(stat.modifiedNs, wal.modifiedNs)
        }
        return stat
    }

    static func fstat(_ descriptor: Int32) -> FileStat? {
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        return FileStat(info)
    }
}
