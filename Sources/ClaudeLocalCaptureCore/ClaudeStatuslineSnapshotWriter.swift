import CryptoKit
import Darwin
import Foundation

/// Writes privacy-filtered statusline snapshots into the app-owned cache.
///
/// The default location is `<Application Support>/CodexTokenBar/claude-local-statusline`.
/// Session filenames contain only a SHA-256 digest; `latest.json` is an independent
/// last-capture pointer. The directory is kept at mode 0700 and files at 0600. Writes
/// use an exclusive same-directory temporary file followed by an atomic rename.
public final class ClaudeStatuslineSnapshotWriter {
    public static let maximumSessionFiles = 64

    private let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL? = nil) {
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        } else {
            self.applicationSupportDirectory = (FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)).standardizedFileURL
        }
    }

    /// The app-owned cache directory. Exposed for diagnostics and tests; the executable
    /// does not accept an arbitrary destination from its command line.
    public var cacheDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("CodexTokenBar", isDirectory: true)
            .appendingPathComponent("claude-local-statusline", isDirectory: true)
    }

    public func write(_ snapshot: ClaudeStatuslineSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= ClaudeStatuslineParser.maximumInputBytes else {
            throw ClaudeStatuslineCaptureError.invalidJSON
        }

        let directoryFD = try openCacheDirectory()
        defer { _ = Darwin.close(directoryFD) }

        let latestName = "latest.json"
        let sessionName = snapshot.sessionId.map(Self.sessionFilename(for:))
        try ensureSafeDestination(latestName, directoryFD: directoryFD)
        if let sessionName {
            try ensureSafeDestination(sessionName, directoryFD: directoryFD)
        }

        if let sessionName {
            try writeAtomically(data, name: sessionName, directoryFD: directoryFD)
        }
        try writeAtomically(data, name: latestName, directoryFD: directoryFD)

        try pruneOldSessionFiles(
            in: directoryFD,
            preserving: sessionName
        )
    }

    public static func sessionFilename(for sessionId: String) -> String {
        let digest = SHA256.hash(data: Data(sessionId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "session-\(hex).json"
    }

    private func openCacheDirectory() throws -> Int32 {
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.path.hasPrefix("/")
        else {
            throw ClaudeStatuslineCaptureError.unsafeCachePath
        }

        let supportFD = applicationSupportDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard supportFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw ClaudeStatuslineCaptureError.unsafeCachePath
            }
            throw fileSystemError("open Application Support", errno)
        }
        defer { _ = Darwin.close(supportFD) }

        let appDirectoryFD = try openOrCreateDirectory("CodexTokenBar", under: supportFD)
        defer { _ = Darwin.close(appDirectoryFD) }

        return try openOrCreateDirectory("claude-local-statusline", under: appDirectoryFD)
    }

    private func openOrCreateDirectory(_ name: String, under parentFD: Int32) throws -> Int32 {
        let mkdirResult = name.withCString { Darwin.mkdirat(parentFD, $0, mode_t(0o700)) }
        if mkdirResult != 0 && errno != EEXIST {
            throw fileSystemError("create cache directory", errno)
        }

        let directoryFD = name.withCString {
            Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            throw ClaudeStatuslineCaptureError.unsafeCachePath
        }

        var metadata = Darwin.stat()
        guard Darwin.fstat(directoryFD, &metadata) == 0 else {
            let code = errno
            _ = Darwin.close(directoryFD)
            throw fileSystemError("inspect cache directory", code)
        }
        guard metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            _ = Darwin.close(directoryFD)
            throw ClaudeStatuslineCaptureError.unsafeCachePath
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            let code = errno
            _ = Darwin.close(directoryFD)
            throw fileSystemError("secure cache directory", code)
        }
        return directoryFD
    }

    private func ensureSafeDestination(_ name: String, directoryFD: Int32) throws {
        var metadata = Darwin.stat()
        let result = name.withCString {
            Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == Darwin.geteuid()
            else {
                throw ClaudeStatuslineCaptureError.unsafeCachePath
            }
        } else if errno != ENOENT {
            throw fileSystemError("inspect cache file", errno)
        }
    }

    private func writeAtomically(_ data: Data, name: String, directoryFD: Int32) throws {
        try ensureSafeDestination(name, directoryFD: directoryFD)

        let temporaryName = ".tmp-\(UUID().uuidString.lowercased())"
        let fileFD = temporaryName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard fileFD >= 0 else {
            throw fileSystemError("create temporary cache file", errno)
        }

        var renamed = false
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(fileFD) }
            if !renamed {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw fileSystemError("secure cache file", errno)
        }
        try writeAll(data, to: fileFD)
        guard Darwin.fsync(fileFD) == 0 else {
            throw fileSystemError("flush cache file", errno)
        }
        guard Darwin.close(fileFD) == 0 else {
            isOpen = false
            throw fileSystemError("close cache file", errno)
        }
        isOpen = false

        try ensureSafeDestination(name, directoryFD: directoryFD)
        let renameResult = temporaryName.withCString { temporary in
            name.withCString { destination in
                Darwin.renameat(directoryFD, temporary, directoryFD, destination)
            }
        }
        guard renameResult == 0 else {
            throw fileSystemError("publish cache file", errno)
        }
        renamed = true
        guard Darwin.fsync(directoryFD) == 0 else {
            throw fileSystemError("flush cache directory", errno)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw fileSystemError("write cache file", errno)
                }
                guard count > 0 else {
                    throw fileSystemError("write cache file", EIO)
                }
                offset += count
            }
        }
    }

    private func pruneOldSessionFiles(in directoryFD: Int32, preserving protectedName: String?) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        var files: [(name: String, modifiedSeconds: Int64, modifiedNanoseconds: Int64)] = []

        for name in names where Self.isSessionFilename(name) && name != protectedName {
            var metadata = Darwin.stat()
            let result = name.withCString {
                Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError("inspect session cache file", errno)
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == Darwin.geteuid()
            else {
                // Never follow, replace, or delete non-regular entries during rotation.
                continue
            }
            files.append((name, Int64(metadata.st_mtimespec.tv_sec), Int64(metadata.st_mtimespec.tv_nsec)))
        }

        let protectedCount = protectedName == nil ? 0 : 1
        let removalsNeeded = max(0, files.count + protectedCount - Self.maximumSessionFiles)
        let oldestFirst = files.sorted {
            if $0.modifiedSeconds != $1.modifiedSeconds {
                return $0.modifiedSeconds < $1.modifiedSeconds
            }
            if $0.modifiedNanoseconds != $1.modifiedNanoseconds {
                return $0.modifiedNanoseconds < $1.modifiedNanoseconds
            }
            return $0.name < $1.name
        }

        for entry in oldestFirst.prefix(removalsNeeded) {
            var metadata = Darwin.stat()
            let result = entry.name.withCString {
                Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError("inspect session cache file", errno)
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == Darwin.geteuid()
            else {
                continue
            }
            let unlinkResult = entry.name.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            if unlinkResult != 0 && errno != ENOENT {
                throw fileSystemError("rotate session cache", errno)
            }
        }
    }

    private static func isSessionFilename(_ name: String) -> Bool {
        guard name.hasPrefix("session-"), name.hasSuffix(".json") else { return false }
        let digest = name.dropFirst("session-".count).dropLast(".json".count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func fileSystemError(_ operation: String, _ code: Int32) -> ClaudeStatuslineCaptureError {
        .fileSystemFailure(operation, code)
    }
}
