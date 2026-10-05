import Darwin
import Foundation

/// A cheap invalidation hint shared by the snapshot cache and the exact index.
/// Physical identity comes from stat/fstat; rollout size addresses decoded bytes.
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
        let logical = CodexRolloutReader.logicalURL(file)
        var status = Darwin.stat()
        if lstat(logical.path, &status) == 0 { return try Self(status: status) }
        let code = errno
        guard CodexRolloutReader.isRollout(file), code == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: logical.path])
        }
        let handle = try CodexRolloutReader(forReadingFrom: file)
        defer { try? handle.close() }
        return try read(handle: handle)
    }

    /// Observe the preferred on-disk representation without opening a zstd
    /// decoder. The returned size is physical; callers that already trust a
    /// logical JSONL length can apply it with `withLogicalSize(_:)`.
    static func readPreferredPhysical(at file: URL) throws -> (file: URL, observation: Self) {
        guard CodexRolloutReader.isRollout(file) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        let logical = CodexRolloutReader.logicalURL(file)
        var lastError: Error = CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: logical.path])

        for _ in 0..<3 {
            let physical: URL
            let namedObservation: Self
            var namedStatus = Darwin.stat()
            if lstat(logical.path, &namedStatus) == 0 {
                // An existing plain path is authoritative, including unsafe
                // entries. Never fall back to its compressed sibling.
                physical = logical
                namedObservation = try Self(status: namedStatus)
            } else {
                let logicalError = errno
                guard logicalError == ENOENT, logical.pathExtension == "jsonl" else {
                    throw Self.posixError(logicalError, path: logical.path)
                }
                physical = URL(fileURLWithPath: logical.path + ".zst")
                guard lstat(physical.path, &namedStatus) == 0 else {
                    let code = errno
                    lastError = Self.posixError(code, path: physical.path)
                    if code == ENOENT { continue }
                    throw lastError
                }
                namedObservation = try Self(status: namedStatus)
            }

            do {
                let handle = try FileHandle(forReadingFrom: physical)
                CodexRolloutReader.recordPhysicalOpenForCurrentThread()
                defer { try? handle.close() }

                let openedObservation = try readPhysical(handle: handle)
                guard openedObservation.matches(namedObservation) else {
                    lastError = Self.changedError(path: physical.path)
                    continue
                }

                var afterStatus = Darwin.stat()
                guard lstat(physical.path, &afterStatus) == 0 else {
                    let code = errno
                    lastError = Self.posixError(code, path: physical.path)
                    if code == ENOENT { continue }
                    throw lastError
                }
                let afterObservation = try Self(status: afterStatus)
                guard openedObservation.matches(afterObservation) else {
                    lastError = Self.changedError(path: physical.path)
                    continue
                }

                // A plain sibling appearing while the compressed file was
                // opened takes precedence; retry and validate that path.
                if physical.lastPathComponent.hasSuffix(".jsonl.zst"),
                   lstat(logical.path, &namedStatus) == 0 {
                    lastError = Self.changedError(path: logical.path)
                    continue
                }
                return (physical, openedObservation)
            } catch {
                let value = error as NSError
                guard (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
                    || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
                else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    static func read(handle: FileHandle) throws -> Self {
        try readPhysical(handle: handle)
    }

    static func read(handle: any CodexReadHandle) throws -> Self {
        let observed = try readPhysical(handle: handle.physicalHandle)
        return Self(size: try handle.logicalSize(), modifiedAt: observed.modifiedAt, physicalStamp: observed.physicalStamp)
    }

    private init(size: UInt64, modifiedAt: TimeInterval, physicalStamp: String) {
        self.size = size; self.modifiedAt = modifiedAt; self.physicalStamp = physicalStamp
    }

    func matches(_ other: Self) -> Bool {
        size == other.size && modifiedAt == other.modifiedAt && physicalStamp == other.physicalStamp
    }

    func withLogicalSize(_ logicalSize: UInt64) -> Self {
        Self(size: logicalSize, modifiedAt: modifiedAt, physicalStamp: physicalStamp)
    }

    static func readPhysical(handle: FileHandle) throws -> Self {
        var status = Darwin.stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return try Self(status: status)
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    private static func changedError(path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE), userInfo: [NSFilePathErrorKey: path])
    }
}
