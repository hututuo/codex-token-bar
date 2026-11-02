import Darwin
import Foundation

/// Independent of A/B and the 15-second startup trace. One durable JSONL file
/// per attempt; no source rows, raw conversations or credentials are collected.
final class BusinessMigrationDiagnostics: @unchecked Sendable {
    struct Event: Codable, Sendable {
        let schemaVersion: Int
        let attemptId: String
        let sequence: Int
        let timestampMs: Int64
        let elapsedMs: UInt64
        let stage: String
        let status: String
        let details: [String: String]
    }
    struct PreviewSnapshot: Sendable {
        let attemptID: String?
        let persistenceError: String?
        let text: String
    }
    let attemptID = UUID().uuidString
    let url: URL
    private let lock = NSLock()
    private var file: FileHandle?
    private var sequence = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private var failure: String?
    private var tail: [String] = []
    private let beforePersistForTesting: (@Sendable (Event) throws -> Void)?
    private static let latestLock = NSLock()
    nonisolated(unsafe) private static var latest: BusinessMigrationDiagnostics?

    init(root: URL, operation: String,
         beforePersistForTesting: (@Sendable (Event) throws -> Void)? = nil) {
        self.beforePersistForTesting = beforePersistForTesting
        url = root.appendingPathComponent("attempt-\(attemptID).jsonl")
        do {
            try Self.validateDirectory(root, create: true)
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Self.posixError() }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch { failure = error.localizedDescription }
        Self.latestLock.lock(); Self.latest = self; Self.latestLock.unlock()
        record("attempt", "started", ["operation": operation, "platform": "macOS",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"])
    }
    func record(_ stage: String, _ status: String, _ details: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let event = Event(schemaVersion: 1, attemptId: attemptID, sequence: sequence,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
            elapsedMs: (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            stage: stage, status: status, details: details)
        do {
            var data = try JSONEncoder().encode(event); data.append(10)
            tail.append(String(decoding: data, as: UTF8.self))
            if tail.count > 100 { tail.removeFirst(tail.count - 100) }
            // Tests can hold the real writer at its persistence boundary. The
            // normal write and fsync below always retain their durable behavior.
            try beforePersistForTesting?(event)
            try file?.write(contentsOf: data)
            if let file, Darwin.fsync(file.fileDescriptor) != 0 { throw Self.posixError() }
        } catch { failure = error.localizedDescription; file = nil }
    }
    func perform<T>(_ stage: String, subject: String = "", _ operation: () throws -> T) throws -> T {
        record(stage, "started", ["subject": subject])
        do { let result = try operation(); record(stage, "succeeded", ["subject": subject]); return result }
        catch { record(stage, "failed", ["subject": subject, "error": String(describing: error)]); throw error }
    }
    func finish(_ error: Error? = nil) {
        record("attempt", error == nil ? "succeeded" : "failed", error.map { ["error": String(describing: $0)] } ?? [:])
    }
    var persistenceError: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var memoryPreview: String { lock.lock(); defer { lock.unlock() }; return tail.joined() }
    static var currentMemoryPreview: String {
        latestLock.lock(); let current = latest; latestLock.unlock(); return current?.memoryPreview ?? ""
    }
    static var currentPersistenceError: String? {
        latestLock.lock(); let current = latest; latestLock.unlock(); return current?.persistenceError
    }
    private var previewSnapshot: PreviewSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(attemptID: attemptID, persistenceError: failure, text: tail.joined())
    }
    static var currentPreviewSnapshot: PreviewSnapshot? {
        latestLock.lock(); let current = latest; latestLock.unlock()
        // Capture one attempt before waiting for its writer. A retry may replace
        // latest while that wait is suspended; error and text must still agree.
        return current?.previewSnapshot
    }
    /// UI entry point: even an in-memory preview can wait behind write/fsync.
    /// Keep both that wait and the disk fallback off the main actor.
    @MainActor static func readPreview(at root: URL? = nil) async -> PreviewSnapshot {
        await Task.detached(priority: .utility) {
            if let current = currentPreviewSnapshot { return current }
            do {
                let directory = try root ?? productionDirectory()
                return PreviewSnapshot(attemptID: nil, persistenceError: nil, text: try preview(at: directory))
            } catch {
                return PreviewSnapshot(attemptID: nil, persistenceError: nil,
                    text: "读取诊断失败：\(error.localizedDescription)")
            }
        }.value
    }
    static func productionDirectory() throws -> URL {
        try BusinessDatabaseMigration.Configuration.production().container.deletingLastPathComponent()
            .appendingPathComponent("migration-diagnostics", isDirectory: true)
    }
    static func exportToSupportDirectory() throws -> URL {
        let root = try productionDirectory()
        let output = root.appendingPathComponent("exports", isDirectory: true)
        try validateDirectory(output, create: true)
        let target = output.appendingPathComponent("TokenBar_migration_\(UUID().uuidString).log")
        try export(at: root, to: target)
        return target
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func validateDirectory(_ root: URL, create: Bool) throws {
        if create && !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    static func files(at root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try validateDirectory(root, create: false)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent
                return url.pathExtension == "jsonl" && name.hasPrefix("attempt-") && UUID(uuidString: String(name.dropFirst(8))) != nil
            }.map { url in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
                return url
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// The UI shows a bounded preview, but export streams ALL retained attempts.
    static func preview(at root: URL) throws -> String {
        let paths = try files(at: root).sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        guard let path = paths.last else { return "尚无已保存的迁移日志" }
        let input = try openLog(path); defer { try? input.close() }
        let end = try input.seekToEnd(); let offset = end > 64 * 1024 ? end - 64 * 1024 : 0
        try input.seek(toOffset: offset)
        let text = String(decoding: try input.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.dropFirst(offset > 0 ? 1 : 0).suffix(100).joined(separator: "\n")
    }
    private static func openLog(_ path: URL) throws -> FileHandle {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    /// Plain UTF-8 diagnostic bundle; no shell archiver, no recursive traversal,
    /// and no copying of business databases. Output must be a new private file.
    static func export(at root: URL, to target: URL) throws {
        let paths = try files(at: root)
        guard !paths.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try output.write(contentsOf: Data("Token Bar migration diagnostics v1\nMay contain local paths and errors. Inspect before sharing. Missing attempt completion denotes interruption. Active files are copied through a fixed byte boundary.\n\n".utf8))
            for path in paths {
                let input = try openLog(path); defer { try? input.close() }
                var remaining = try input.seekToEnd(); try input.seek(toOffset: 0)
                try output.write(contentsOf: Data("\n=== \(path.lastPathComponent) ===\n".utf8))
                while remaining > 0 {
                    let data = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                    guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try output.write(contentsOf: data); remaining -= UInt64(data.count)
                }
            }
            if let current = currentPreviewSnapshot, let failure = current.persistenceError {
                try output.write(contentsOf: Data("\nWARNING: current attempt logging failed; this bundle is incomplete: \(failure)\n".utf8))
                try output.write(contentsOf: Data(current.text.utf8))
            }
            guard Darwin.fsync(output.fileDescriptor) == 0 else { throw posixError() }
            try output.close()
        } catch {
            try? output.close(); try? FileManager.default.removeItem(at: target); throw error
        }
    }
}
