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

struct ProviderSyncIdentityConflictError: LocalizedError {
    let message: String
    let recoveryPaths: [String]

    var errorDescription: String? {
        guard !recoveryPaths.isEmpty else { return message }
        return "\(message)；已保留 recovery path：\(recoveryPaths.joined(separator: "，"))"
    }
}

struct ProviderSyncRegularFileReplacement {
    let file: ProviderSyncPinnedFile
    let retainedOriginalName: String
    let originalIdentity: ProviderSyncFileIdentity
    let replacementIdentity: ProviderSyncFileIdentity
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

final class ProviderSyncBoundRegularFile {
    let file: ProviderSyncPinnedFile
    let descriptor: ProviderSyncOwnedFileDescriptor
    let identity: ProviderSyncFileIdentity
    let metadata: stat

    init(
        file: ProviderSyncPinnedFile,
        descriptor: ProviderSyncOwnedFileDescriptor,
        identity: ProviderSyncFileIdentity,
        metadata: stat
    ) {
        self.file = file
        self.descriptor = descriptor
        self.identity = identity
        self.metadata = metadata
    }

    func close() throws {
        try descriptor.close()
    }
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

    func bindRegularFile(
        relativePath: String,
        requireSingleLink: Bool = false
    ) throws -> ProviderSyncBoundRegularFile? {
        let file = try pinFile(relativePath: relativePath, createParents: false)
        try verifyParent(file)
        guard let metadataBeforeOpen = try entryMetadata(file) else { return nil }
        guard (metadataBeforeOpen.st_mode & S_IFMT) == S_IFREG else {
            throw providerSyncDescriptorError("绑定目标不是常规文件：\(file.displayURL.path)")
        }
        if requireSingleLink, metadataBeforeOpen.st_nlink != 1 {
            throw providerSyncDescriptorError("绑定目标存在 hardlink：\(file.displayURL.path)")
        }
        let identityBeforeOpen = ProviderSyncFileIdentity(metadataBeforeOpen)
        let descriptor = Darwin.openat(
            file.parent.rawValue,
            file.name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw providerSyncPOSIXError("无法绑定相对常规文件：\(file.displayURL.path)")
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        do {
            let metadata = try providerSyncMetadata(descriptor: descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  ProviderSyncFileIdentity(metadata) == identityBeforeOpen else {
                throw providerSyncDescriptorError("绑定文件在 fstatat/open 间发生变化：\(file.displayURL.path)")
            }
            if requireSingleLink, metadata.st_nlink != 1 {
                throw providerSyncDescriptorError("打开后的绑定文件存在 hardlink：\(file.displayURL.path)")
            }
            guard let metadataAfterOpen = try entryMetadata(file),
                  ProviderSyncFileIdentity(metadataAfterOpen) == identityBeforeOpen else {
                throw providerSyncDescriptorError("绑定文件在 open 后发生变化：\(file.displayURL.path)")
            }
            try verifyParent(file)
            return ProviderSyncBoundRegularFile(
                file: file,
                descriptor: owned,
                identity: identityBeforeOpen,
                metadata: metadata
            )
        } catch {
            try? owned.close()
            throw error
        }
    }

    func verifyBoundFile(_ bound: ProviderSyncBoundRegularFile) throws {
        try verifyParent(bound.file)
        let openedMetadata = try providerSyncMetadata(descriptor: bound.descriptor.rawValue)
        guard ProviderSyncFileIdentity(openedMetadata) == bound.identity,
              let entry = try entryMetadata(bound.file),
              ProviderSyncFileIdentity(entry) == bound.identity else {
            throw providerSyncDescriptorError("绑定文件路径身份发生变化：\(bound.file.displayURL.path)")
        }
    }

    func readOptionalRegularFile(
        relativePath: String,
        requireSingleLink: Bool = false
    ) throws -> ProviderSyncRegularFileSnapshot? {
        let file = try pinFile(relativePath: relativePath, createParents: false)
        guard try entryMetadata(file) != nil else {
            try verifyParent(file)
            return nil
        }
        return try readRegularFile(file, requireSingleLink: requireSingleLink)
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

    func replaceRegularFile(
        _ file: ProviderSyncPinnedFile,
        expectedIdentity: ProviderSyncFileIdentity,
        data: Data,
        preserving metadata: stat,
        beforeExchange: (() throws -> Void)? = nil
    ) throws -> ProviderSyncRegularFileReplacement {
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
        let replacementIdentity = ProviderSyncFileIdentity(
            try providerSyncMetadata(descriptor: temporaryDescriptor)
        )
        try temporary.close()

        try verifyParent(file)
        guard let identityBeforeRename = try entryMetadata(file),
              identityBeforeRename.st_nlink == 1,
              ProviderSyncFileIdentity(identityBeforeRename) == expectedIdentity else {
            throw providerSyncDescriptorError("原子替换前 session 身份发生变化：\(file.displayURL.path)")
        }
        try beforeExchange?()
        try providerSyncExchange(
            firstDirectory: file.parent.rawValue,
            firstName: temporaryName,
            secondDirectory: file.parent.rawValue,
            secondName: file.name
        )

        let retainedMetadata = try providerSyncEntryMetadata(
            directory: file.parent.rawValue,
            name: temporaryName
        )
        let replacementMetadata = try entryMetadata(file)
        guard let retainedMetadata,
              let replacementMetadata,
              ProviderSyncFileIdentity(retainedMetadata) == expectedIdentity,
              ProviderSyncFileIdentity(replacementMetadata) == replacementIdentity else {
            let retainedIdentity = retainedMetadata.map(ProviderSyncFileIdentity.init)
            do {
                try providerSyncExchange(
                    firstDirectory: file.parent.rawValue,
                    firstName: temporaryName,
                    secondDirectory: file.parent.rawValue,
                    secondName: file.name
                )
                guard let revertedDestination = try entryMetadata(file),
                      let revertedTemporary = try providerSyncEntryMetadata(
                        directory: file.parent.rawValue,
                        name: temporaryName
                      ),
                      ProviderSyncFileIdentity(revertedTemporary) == replacementIdentity,
                      retainedIdentity == nil
                        || ProviderSyncFileIdentity(revertedDestination) == retainedIdentity else {
                    temporaryExists = false
                    throw ProviderSyncIdentityConflictError(
                        message: "session identity mismatch，atomic revert 后身份无法确认",
                        recoveryPaths: [
                            file.displayURL.path,
                            file.displayURL.deletingLastPathComponent()
                                .appendingPathComponent(temporaryName).path
                        ]
                    )
                }
            } catch let conflict as ProviderSyncIdentityConflictError {
                throw conflict
            } catch {
                temporaryExists = false
                throw ProviderSyncIdentityConflictError(
                    message: "session identity mismatch，atomic revert 失败：\(error.localizedDescription)",
                    recoveryPaths: [
                        file.displayURL.path,
                        file.displayURL.deletingLastPathComponent()
                            .appendingPathComponent(temporaryName).path
                    ]
                )
            }
            throw ProviderSyncIdentityConflictError(
                message: "session destination 在最终检查与 exchange 之间发生身份变化",
                recoveryPaths: [file.displayURL.path]
            )
        }

        try verifyParent(file)
        let result = try readRegularFile(
            file,
            expectedIdentity: replacementIdentity,
            requireSingleLink: true
        )
        guard providerSyncSHA256Hex(result.data) == providerSyncSHA256Hex(data) else {
            temporaryExists = false
            throw ProviderSyncIdentityConflictError(
                message: "session replacement 写后摘要不一致",
                recoveryPaths: [
                    file.displayURL.path,
                    file.displayURL.deletingLastPathComponent()
                        .appendingPathComponent(temporaryName).path
                ]
            )
        }
        temporaryExists = false
        return ProviderSyncRegularFileReplacement(
            file: file,
            retainedOriginalName: temporaryName,
            originalIdentity: expectedIdentity,
            replacementIdentity: result.identity
        )
    }

    func commitRegularFileReplacement(_ replacement: ProviderSyncRegularFileReplacement) throws {
        try verifyParent(replacement.file)
        guard let current = try entryMetadata(replacement.file),
              ProviderSyncFileIdentity(current) == replacement.replacementIdentity,
              let retained = try providerSyncEntryMetadata(
                directory: replacement.file.parent.rawValue,
                name: replacement.retainedOriginalName
              ),
              ProviderSyncFileIdentity(retained) == replacement.originalIdentity else {
            throw ProviderSyncIdentityConflictError(
                message: "replacement commit 前 destination 或 retained original 身份发生变化",
                recoveryPaths: [
                    replacement.file.displayURL.path,
                    replacement.file.displayURL.deletingLastPathComponent()
                        .appendingPathComponent(replacement.retainedOriginalName).path
                ]
            )
        }
        try providerSyncUnlinkIfExists(
            directory: replacement.file.parent.rawValue,
            name: replacement.retainedOriginalName
        )
    }

    func rollbackRegularFileReplacement(_ replacement: ProviderSyncRegularFileReplacement) throws {
        try verifyParent(replacement.file)
        guard let current = try entryMetadata(replacement.file),
              let retained = try providerSyncEntryMetadata(
                directory: replacement.file.parent.rawValue,
                name: replacement.retainedOriginalName
              ),
              ProviderSyncFileIdentity(current) == replacement.replacementIdentity,
              ProviderSyncFileIdentity(retained) == replacement.originalIdentity else {
            throw ProviderSyncIdentityConflictError(
                message: "session rollback 前 identity 不一致",
                recoveryPaths: [
                    replacement.file.displayURL.path,
                    replacement.file.displayURL.deletingLastPathComponent()
                        .appendingPathComponent(replacement.retainedOriginalName).path
                ]
            )
        }
        try providerSyncExchange(
            firstDirectory: replacement.file.parent.rawValue,
            firstName: replacement.retainedOriginalName,
            secondDirectory: replacement.file.parent.rawValue,
            secondName: replacement.file.name
        )
        guard let restored = try entryMetadata(replacement.file),
              let discardedReplacement = try providerSyncEntryMetadata(
                directory: replacement.file.parent.rawValue,
                name: replacement.retainedOriginalName
              ),
              ProviderSyncFileIdentity(restored) == replacement.originalIdentity,
              ProviderSyncFileIdentity(discardedReplacement) == replacement.replacementIdentity else {
            throw ProviderSyncIdentityConflictError(
                message: "session rollback exchange 后 identity 不一致",
                recoveryPaths: [
                    replacement.file.displayURL.path,
                    replacement.file.displayURL.deletingLastPathComponent()
                        .appendingPathComponent(replacement.retainedOriginalName).path
                ]
            )
        }
        try providerSyncUnlinkIfExists(
            directory: replacement.file.parent.rawValue,
            name: replacement.retainedOriginalName
        )
    }

    @discardableResult
    func createRegularFileAtomically(
        _ file: ProviderSyncPinnedFile,
        data: Data,
        metadata: stat? = nil,
        beforePlacement: (() throws -> Void)? = nil
    ) throws -> ProviderSyncFileIdentity {
        try verifyParent(file)
        guard try entryMetadata(file) == nil else {
            throw ProviderSyncIdentityConflictError(
                message: "atomic create 前目标已存在",
                recoveryPaths: [file.displayURL.path]
            )
        }
        let temporaryName = ".provider-fixed-write-\(UUID().uuidString)"
        try providerSyncCreateRegularFile(
            directory: file.parent.rawValue,
            name: temporaryName,
            data: data,
            metadata: metadata
        )
        var temporaryExists = true
        defer {
            if temporaryExists {
                try? providerSyncUnlinkIfExists(
                    directory: file.parent.rawValue,
                    name: temporaryName
                )
            }
        }
        guard let temporaryMetadata = try providerSyncEntryMetadata(
            directory: file.parent.rawValue,
            name: temporaryName
        ) else {
            throw providerSyncDescriptorError("atomic create temporary 缺失")
        }
        let temporaryIdentity = ProviderSyncFileIdentity(temporaryMetadata)
        try beforePlacement?()
        try verifyParent(file)
        try providerSyncRenameExclusive(
            fromDirectory: file.parent.rawValue,
            fromName: temporaryName,
            toDirectory: file.parent.rawValue,
            toName: file.name
        )
        temporaryExists = false
        let result = try readRegularFile(
            file,
            expectedIdentity: temporaryIdentity,
            requireSingleLink: true
        )
        guard providerSyncSHA256Hex(result.data) == providerSyncSHA256Hex(data) else {
            throw providerSyncDescriptorError("atomic create 写后摘要不一致：\(file.displayURL.path)")
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

    func verifyRootPathIdentity() throws {
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

func providerSyncDescriptorPath(_ descriptor: Int32) -> URL? {
    guard descriptor >= 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
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
    name: String,
    expectedIdentity: ProviderSyncFileIdentity? = nil,
    willOpen: (() throws -> Void)? = nil,
    didRead: (() throws -> Void)? = nil
) throws -> ProviderSyncRegularFileSnapshot {
    guard let metadataBeforeOpen = try providerSyncEntryMetadata(directory: directory, name: name),
          (metadataBeforeOpen.st_mode & S_IFMT) == S_IFREG else {
        throw providerSyncDescriptorError("descriptor 相对 entry 不是常规文件：\(name)")
    }
    let identityBeforeOpen = ProviderSyncFileIdentity(metadataBeforeOpen)
    if let expectedIdentity, identityBeforeOpen != expectedIdentity {
        throw providerSyncDescriptorError("descriptor 相对 entry 身份发生变化：\(name)")
    }
    try willOpen?()
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
    let openedIdentity = ProviderSyncFileIdentity(metadata)
    guard openedIdentity == identityBeforeOpen,
          expectedIdentity == nil || openedIdentity == expectedIdentity else {
        throw providerSyncDescriptorError("descriptor 相对 entry 在 precheck/open 间发生变化：\(name)")
    }
    let data = try providerSyncReadAll(descriptor: descriptor)
    try didRead?()
    guard let metadataAfterRead = try providerSyncEntryMetadata(directory: directory, name: name),
          ProviderSyncFileIdentity(metadataAfterRead) == openedIdentity else {
        throw providerSyncDescriptorError("descriptor 相对 entry 在读取期间发生变化：\(name)")
    }
    return ProviderSyncRegularFileSnapshot(
        data: data,
        identity: openedIdentity,
        metadata: metadata
    )
}

func providerSyncExchange(
    firstDirectory: Int32,
    firstName: String,
    secondDirectory: Int32,
    secondName: String
) throws {
    guard renameatx_np(
        firstDirectory,
        firstName,
        secondDirectory,
        secondName,
        UInt32(RENAME_SWAP)
    ) == 0 else {
        throw providerSyncPOSIXError("descriptor 相对 atomic exchange 失败：\(firstName) <-> \(secondName)")
    }
}

func providerSyncRenameExclusive(
    fromDirectory: Int32,
    fromName: String,
    toDirectory: Int32,
    toName: String
) throws {
    guard renameatx_np(
        fromDirectory,
        fromName,
        toDirectory,
        toName,
        UInt32(RENAME_EXCL)
    ) == 0 else {
        throw providerSyncPOSIXError("descriptor 相对 exclusive rename 失败：\(fromName) -> \(toName)")
    }
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
