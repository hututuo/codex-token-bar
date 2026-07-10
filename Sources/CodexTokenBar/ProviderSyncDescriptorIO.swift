import CryptoKit
import Darwin
import Foundation

struct ProviderSyncFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(UInt32(bitPattern: metadata.st_dev))
        inode = UInt64(metadata.st_ino)
    }
}

struct ProviderSyncRegularFileSnapshot {
    let data: Data
    let identity: ProviderSyncFileIdentity
    let metadata: stat
}

final class ProviderSyncOwnedFileDescriptor {
    private(set) var rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    func close() throws {
        guard rawValue >= 0 else { return }
        let descriptor = rawValue
        rawValue = -1
        guard Darwin.close(descriptor) == 0 else {
            throw providerSyncPOSIXError("关闭文件描述符失败")
        }
    }

    deinit {
        if rawValue >= 0 {
            Darwin.close(rawValue)
        }
    }
}

struct ProviderSyncPinnedFile {
    let relativePath: String
    let parentComponents: [String]
    let name: String
    let parent: ProviderSyncOwnedFileDescriptor
    let parentIdentity: ProviderSyncFileIdentity
    let displayURL: URL
    let createdDirectories: [String]
}

final class ProviderSyncHomeDirectory {
    let canonicalURL: URL
    let identity: ProviderSyncFileIdentity
    private let root: ProviderSyncOwnedFileDescriptor

    init(canonicalURL: URL) throws {
        self.canonicalURL = canonicalURL
        let descriptor = Darwin.open(
            canonicalURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw providerSyncPOSIXError("无法固定 canonical Codex Home：\(canonicalURL.path)")
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        do {
            let metadata = try providerSyncMetadata(descriptor: descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw providerSyncDescriptorError("canonical Codex Home 不是目录：\(canonicalURL.path)")
            }
            root = owned
            identity = ProviderSyncFileIdentity(metadata)
        } catch {
            try? owned.close()
            throw error
        }
    }

    var descriptor: Int32 { root.rawValue }

    func close() throws {
        try root.close()
    }

    func pinFile(relativePath: String, createParents: Bool) throws -> ProviderSyncPinnedFile {
        let components = try providerSyncRelativePathComponents(relativePath)
        let parentComponents = Array(components.dropLast())
        let opened = try openDirectory(
            components: parentComponents,
            createMissing: createParents
        )
        return ProviderSyncPinnedFile(
            relativePath: relativePath,
            parentComponents: parentComponents,
            name: components[components.count - 1],
            parent: opened.descriptor,
            parentIdentity: opened.identity,
            displayURL: canonicalURL.appendingPathComponent(relativePath),
            createdDirectories: opened.createdDirectories
        )
    }

    func verifyParent(_ file: ProviderSyncPinnedFile) throws {
        try verifyRootPathIdentity()
        let reopened = try openDirectory(
            components: file.parentComponents,
            createMissing: false
        )
        defer { try? reopened.descriptor.close() }
        guard reopened.identity == file.parentIdentity else {
            throw providerSyncDescriptorError(
                "目标父目录身份发生变化：\(file.displayURL.deletingLastPathComponent().path)"
            )
        }
    }

    func entryMetadata(_ file: ProviderSyncPinnedFile) throws -> stat? {
        var metadata = stat()
        if fstatat(file.parent.rawValue, file.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return metadata
        }
        if errno == ENOENT { return nil }
        throw providerSyncPOSIXError("读取相对目标元数据失败：\(file.displayURL.path)")
    }

    func readRegularFile(
        _ file: ProviderSyncPinnedFile,
        expectedIdentity: ProviderSyncFileIdentity? = nil,
        requireSingleLink: Bool = false
    ) throws -> ProviderSyncRegularFileSnapshot {
        try verifyParent(file)
        let descriptor = Darwin.openat(
            file.parent.rawValue,
            file.name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw providerSyncPOSIXError("无法无跟随打开相对文件：\(file.displayURL.path)")
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }

        let metadata = try providerSyncMetadata(descriptor: descriptor)
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw providerSyncDescriptorError("相对文件不是常规文件：\(file.displayURL.path)")
        }
        if requireSingleLink, metadata.st_nlink != 1 {
            throw providerSyncDescriptorError("相对文件存在 hardlink：\(file.displayURL.path)")
        }
        let openedIdentity = ProviderSyncFileIdentity(metadata)
        if let expectedIdentity, openedIdentity != expectedIdentity {
            throw providerSyncDescriptorError("相对文件身份发生变化：\(file.displayURL.path)")
        }
        let data = try providerSyncReadAll(descriptor: descriptor)
        guard let currentMetadata = try entryMetadata(file),
              ProviderSyncFileIdentity(currentMetadata) == openedIdentity else {
            throw providerSyncDescriptorError("相对文件在读取期间被替换：\(file.displayURL.path)")
        }
        try verifyParent(file)
        return ProviderSyncRegularFileSnapshot(
            data: data,
            identity: openedIdentity,
            metadata: metadata
        )
    }

    @discardableResult
    func replaceRegularFile(
        _ file: ProviderSyncPinnedFile,
        expectedIdentity: ProviderSyncFileIdentity,
        data: Data,
        preserving metadata: stat
    ) throws -> ProviderSyncFileIdentity {
        try verifyParent(file)
        guard let currentMetadata = try entryMetadata(file),
              (currentMetadata.st_mode & S_IFMT) == S_IFREG,
              currentMetadata.st_nlink == 1,
              ProviderSyncFileIdentity(currentMetadata) == expectedIdentity else {
            throw providerSyncDescriptorError("写入前相对文件身份发生变化：\(file.displayURL.path)")
        }

        let temporaryName = ".provider-session-rewrite-\(UUID().uuidString)"
        let temporaryDescriptor = Darwin.openat(
            file.parent.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw providerSyncPOSIXError("无法创建相对 session replacement：\(file.displayURL.path)")
        }
        let temporary = ProviderSyncOwnedFileDescriptor(temporaryDescriptor)
        var temporaryExists = true
        defer {
            try? temporary.close()
            if temporaryExists {
                _ = Darwin.unlinkat(file.parent.rawValue, temporaryName, 0)
            }
        }

        try providerSyncWriteAll(data, descriptor: temporaryDescriptor)
        guard fchmod(temporaryDescriptor, metadata.st_mode & 0o777) == 0 else {
            throw providerSyncPOSIXError("设置 session replacement 权限失败：\(file.displayURL.path)")
        }
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        guard futimens(temporaryDescriptor, &times) == 0 else {
            throw providerSyncPOSIXError("保留 session 修改时间失败：\(file.displayURL.path)")
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw providerSyncPOSIXError("同步 session replacement 失败：\(file.displayURL.path)")
        }
        try temporary.close()

        try verifyParent(file)
        guard let identityBeforeRename = try entryMetadata(file),
              identityBeforeRename.st_nlink == 1,
              ProviderSyncFileIdentity(identityBeforeRename) == expectedIdentity else {
            throw providerSyncDescriptorError("原子替换前 session 身份发生变化：\(file.displayURL.path)")
        }
        guard Darwin.renameat(
            file.parent.rawValue,
            temporaryName,
            file.parent.rawValue,
            file.name
        ) == 0 else {
            throw providerSyncPOSIXError("原子替换 session 失败：\(file.displayURL.path)")
        }
        temporaryExists = false

        try verifyParent(file)
        let result = try readRegularFile(file, requireSingleLink: true)
        guard providerSyncSHA256Hex(result.data) == providerSyncSHA256Hex(data) else {
            throw providerSyncDescriptorError("session replacement 写后摘要不一致：\(file.displayURL.path)")
        }
        return result.identity
    }

    func setModificationTime(
        _ file: ProviderSyncPinnedFile,
        expectedIdentity: ProviderSyncFileIdentity,
        milliseconds: Int64
    ) throws {
        try verifyParent(file)
        let descriptor = Darwin.openat(
            file.parent.rawValue,
            file.name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw providerSyncPOSIXError("无法无跟随打开 session 以更新时间：\(file.displayURL.path)")
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }

        let metadata = try providerSyncMetadata(descriptor: descriptor)
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              ProviderSyncFileIdentity(metadata) == expectedIdentity else {
            throw providerSyncDescriptorError("更新时间前 session 身份发生变化：\(file.displayURL.path)")
        }
        guard let entryBeforeUpdate = try entryMetadata(file),
              ProviderSyncFileIdentity(entryBeforeUpdate) == expectedIdentity else {
            throw providerSyncDescriptorError("更新时间前 session entry 发生变化：\(file.displayURL.path)")
        }

        let seconds = milliseconds / 1_000
        let nanoseconds = (milliseconds % 1_000) * 1_000_000
        var times = [
            metadata.st_atimespec,
            timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
        ]
        guard futimens(descriptor, &times) == 0 else {
            throw providerSyncPOSIXError("更新 descriptor session 时间失败：\(file.displayURL.path)")
        }

        guard let entryAfterUpdate = try entryMetadata(file),
              ProviderSyncFileIdentity(entryAfterUpdate) == expectedIdentity else {
            throw providerSyncDescriptorError("更新时间期间 session entry 发生变化：\(file.displayURL.path)")
        }
        try verifyParent(file)
    }

    func removeCreatedDirectoryIfEmpty(relativePath: String) {
        guard let components = try? providerSyncRelativePathComponents(relativePath),
              !components.isEmpty else { return }
        let parentComponents = Array(components.dropLast())
        guard let parent = try? openDirectory(components: parentComponents, createMissing: false) else {
            return
        }
        defer { try? parent.descriptor.close() }
        _ = Darwin.unlinkat(
            parent.descriptor.rawValue,
            components[components.count - 1],
            AT_REMOVEDIR
        )
    }

    private func verifyRootPathIdentity() throws {
        let descriptor = Darwin.open(
            canonicalURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw providerSyncPOSIXError("canonical Codex Home 路径身份不可用：\(canonicalURL.path)")
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }
        let metadata = try providerSyncMetadata(descriptor: descriptor)
        guard ProviderSyncFileIdentity(metadata) == identity else {
            throw providerSyncDescriptorError("canonical Codex Home 路径身份发生变化：\(canonicalURL.path)")
        }
    }

    private func openDirectory(
        components: [String],
        createMissing: Bool
    ) throws -> (
        descriptor: ProviderSyncOwnedFileDescriptor,
        identity: ProviderSyncFileIdentity,
        createdDirectories: [String]
    ) {
        let duplicated = Darwin.dup(root.rawValue)
        guard duplicated >= 0 else {
            throw providerSyncPOSIXError("复制 Codex Home descriptor 失败")
        }
        var current = ProviderSyncOwnedFileDescriptor(duplicated)
        var traversed: [String] = []
        var createdDirectories: [String] = []

        do {
            for component in components {
                var nextDescriptor = Darwin.openat(
                    current.rawValue,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if nextDescriptor < 0, errno == ENOENT, createMissing {
                    guard Darwin.mkdirat(current.rawValue, component, 0o700) == 0 else {
                        throw providerSyncPOSIXError("创建相对目录失败：\((traversed + [component]).joined(separator: "/"))")
                    }
                    createdDirectories.append((traversed + [component]).joined(separator: "/"))
                    nextDescriptor = Darwin.openat(
                        current.rawValue,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw providerSyncPOSIXError("无法无跟随打开相对目录：\((traversed + [component]).joined(separator: "/"))")
                }
                let next = ProviderSyncOwnedFileDescriptor(nextDescriptor)
                try current.close()
                current = next
                traversed.append(component)
            }
            let metadata = try providerSyncMetadata(descriptor: current.rawValue)
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw providerSyncDescriptorError("相对 parent 不是目录：\(components.joined(separator: "/"))")
            }
            return (current, ProviderSyncFileIdentity(metadata), createdDirectories)
        } catch {
            try? current.close()
            throw error
        }
    }
}

func providerSyncSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func providerSyncMetadata(descriptor: Int32) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        throw providerSyncPOSIXError("读取 descriptor 元数据失败")
    }
    return metadata
}

func providerSyncEntryMetadata(directory: Int32, name: String) throws -> stat? {
    var metadata = stat()
    if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
        return metadata
    }
    if errno == ENOENT { return nil }
    throw providerSyncPOSIXError("读取相对 entry 元数据失败：\(name)")
}

func providerSyncCreateDirectoryDescriptor(
    parent: Int32,
    name: String
) throws -> ProviderSyncOwnedFileDescriptor {
    guard Darwin.mkdirat(parent, name, 0o700) == 0 else {
        throw providerSyncPOSIXError("创建 descriptor 相对目录失败：\(name)")
    }
    let descriptor = Darwin.openat(
        parent,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        _ = Darwin.unlinkat(parent, name, AT_REMOVEDIR)
        throw providerSyncPOSIXError("打开 descriptor 相对目录失败：\(name)")
    }
    return ProviderSyncOwnedFileDescriptor(descriptor)
}

func providerSyncCreateRegularFile(
    directory: Int32,
    name: String,
    data: Data,
    metadata: stat? = nil
) throws {
    let descriptor = Darwin.openat(
        directory,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        throw providerSyncPOSIXError("创建 descriptor 相对文件失败：\(name)")
    }
    let owned = ProviderSyncOwnedFileDescriptor(descriptor)
    var complete = false
    defer {
        try? owned.close()
        if !complete {
            _ = Darwin.unlinkat(directory, name, 0)
        }
    }
    try providerSyncWriteAll(data, descriptor: descriptor)
    if let metadata {
        guard fchmod(descriptor, metadata.st_mode & 0o777) == 0 else {
            throw providerSyncPOSIXError("设置 descriptor 相对文件权限失败：\(name)")
        }
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        guard futimens(descriptor, &times) == 0 else {
            throw providerSyncPOSIXError("设置 descriptor 相对文件时间失败：\(name)")
        }
    }
    guard fsync(descriptor) == 0 else {
        throw providerSyncPOSIXError("同步 descriptor 相对文件失败：\(name)")
    }
    try owned.close()
    complete = true
}

func providerSyncReadRegularFile(
    directory: Int32,
    name: String
) throws -> ProviderSyncRegularFileSnapshot {
    let descriptor = Darwin.openat(
        directory,
        name,
        O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        throw providerSyncPOSIXError("打开 descriptor 相对常规文件失败：\(name)")
    }
    let owned = ProviderSyncOwnedFileDescriptor(descriptor)
    defer { try? owned.close() }
    let metadata = try providerSyncMetadata(descriptor: descriptor)
    guard (metadata.st_mode & S_IFMT) == S_IFREG else {
        throw providerSyncDescriptorError("descriptor 相对 entry 不是常规文件：\(name)")
    }
    return ProviderSyncRegularFileSnapshot(
        data: try providerSyncReadAll(descriptor: descriptor),
        identity: ProviderSyncFileIdentity(metadata),
        metadata: metadata
    )
}

func providerSyncRename(
    fromDirectory: Int32,
    fromName: String,
    toDirectory: Int32,
    toName: String
) throws {
    guard Darwin.renameat(fromDirectory, fromName, toDirectory, toName) == 0 else {
        throw providerSyncPOSIXError("descriptor 相对 rename 失败：\(fromName) -> \(toName)")
    }
}

func providerSyncUnlinkIfExists(
    directory: Int32,
    name: String,
    flags: Int32 = 0
) throws {
    if Darwin.unlinkat(directory, name, flags) == 0 { return }
    if errno == ENOENT { return }
    throw providerSyncPOSIXError("删除 descriptor 相对 entry 失败：\(name)")
}

func providerSyncReadAll(descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw providerSyncPOSIXError("重置读取 descriptor 失败")
    }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count == 0 { return output }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
            throw providerSyncPOSIXError("读取 descriptor 内容失败")
        }
        output.append(buffer, count: count)
    }
}

func providerSyncWriteAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                data.count - offset
            )
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else {
            throw providerSyncPOSIXError("写入 descriptor 内容失败")
        }
        offset += written
    }
}

func providerSyncRelativePathComponents(_ relativePath: String) throws -> [String] {
    guard !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0) else {
        throw providerSyncDescriptorError("相对路径无效：\(relativePath)")
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw providerSyncDescriptorError("相对路径含空组件或 dot 组件：\(relativePath)")
    }
    return components
}

func providerSyncDescriptorError(_ message: String) -> NSError {
    NSError(
        domain: "CodexTokenBar.ProviderDescriptor",
        code: 400,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

func providerSyncPOSIXError(_ message: String, code: Int32 = errno) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: "\(message)：\(String(cString: strerror(code)))"]
    )
}
