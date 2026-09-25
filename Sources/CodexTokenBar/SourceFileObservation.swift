import Darwin
import Foundation

/// A cheap invalidation hint shared by the snapshot cache and the exact index.
/// One stat/fstat supplies all fields; this never opens or hashes file contents.
/// Physical identity is not a ledger identity and is not proof of new usage.
struct SourceFileObservation {
    let size: UInt64
    let modifiedAt: TimeInterval
    let physicalStamp: String

    private init(status: Darwin.stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        size = UInt64(status.st_size)
        modifiedAt = TimeInterval(status.st_mtimespec.tv_sec)
            + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        physicalStamp = "\(status.st_dev):\(status.st_ino):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)"
    }

    static func read(at file: URL) throws -> Self {
        var status = Darwin.stat()
        guard lstat(file.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return try Self(status: status)
    }

    static func read(handle: FileHandle) throws -> Self {
        var status = Darwin.stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return try Self(status: status)
    }
}
