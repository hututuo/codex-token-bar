import Foundation
import Darwin

enum DiagnosticFiles {
    static let maximumFileBytes = 512 * 1024
    /// Open every path component without following links, then operate on the
    /// pinned descriptor. A FIFO/device/symlink cannot turn export into a read.
    static func open(_ url: URL, flags: Int32) throws -> Int32 {
        let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.io }
        defer { Darwin.close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.io }
            Darwin.close(parent); parent = next
        }
        guard let leaf = parts.last else { throw Failure.io }
        let fd = openat(parent, leaf, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.io }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw Failure.io
        }
        return fd
    }
    static func read(_ url: URL, limit: Int = maximumFileBytes) throws -> Data {
        let fd = try open(url, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw Failure.tooLarge }
        return bytes
    }
    static func create(_ url: URL, data: Data) throws {
        let fd = try open(url, flags: O_WRONLY | O_CREAT | O_EXCL)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
    static func safeDirectory(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.standardizedFileURL.pathComponents where part != "/" {
            current.appendPathComponent(part)
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }
    static func ownedDirectory(_ root: URL) throws {
        let fm = FileManager.default
        // Only the diagnostics subtree is created, never a business owner.
        if !fm.fileExists(atPath: root.path) {
            var existing = root.deletingLastPathComponent()
            while !fm.fileExists(atPath: existing.path) && existing.path != "/" { existing.deleteLastPathComponent() }
            guard safeDirectory(existing) else { throw Failure.io }
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard safeDirectory(root) else { throw Failure.io }
        let marker = root.appendingPathComponent("owner.marker")
        if !fm.fileExists(atPath: marker.path) { try create(marker, data: Data("tokenbar-diagnostics-v1\n".utf8)) }
        guard try read(marker, limit: 128) == Data("tokenbar-diagnostics-v1\n".utf8) else { throw Failure.io }
    }
    static func files(_ root: URL, prefix: String, suffix: String) throws -> [URL] {
        guard safeDirectory(root) else { throw Failure.io }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count <= 2048 else { throw Failure.tooLarge }
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    enum Failure: Error { case io, tooLarge }
}
