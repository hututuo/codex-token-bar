import Foundation

/// Best-effort diagnostics, never a recovery journal or an accounting input.
/// The A/B transactions and receipts remain authoritative if this sink fails.
final class RecoveryDiagnostics: @unchecked Sendable {
    enum Phase: String, Codable, Sendable { case preparing, importing, verifying, activating, ready, failure }
    private struct Header: Codable {
        let format: String
        let attempt: String
    }
    private struct Event: Codable {
        let phase: Phase
        let at: Double
        let completed: Int
        let total: Int
        let retryCount: Int
        let code: Int32?
    }
    static let format = "tokenbar-recovery-diagnostic-v1"
    static let marker = Data("tokenbar-recovery-diagnostics-v1\n".utf8)
    private static let sessionLimit = 256 * 1024
    private let queue = DispatchQueue(label: "CodexTokenBar.recovery-diagnostics", qos: .utility)
    private let root: URL
    let fileURL: URL
    private let handle: FileHandle
    private var timer: DispatchSourceTimer?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var written: Int
    private var closed = false
    private let intakeLock = NSLock()
    private var enqueued = 0
    #if DEBUG
    private var failNextFlush = false
    func failNextFlushForTesting() { queue.sync { failNextFlush = true } }
    #endif

    init?(root: URL) {
        do {
            try Self.prepare(root)
            try Self.prune(root: root)
            let attempt = UUID().uuidString.lowercased()
            let file = root.appendingPathComponent("session-\(attempt).jsonl")
            let header = try JSONEncoder().encode(Header(format: Self.format, attempt: attempt)) + Data([10])
            try header.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            self.root = root; fileURL = file; written = header.count
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
            source.setEventHandler { [weak self] in self?.flush() }
            timer = source; source.resume()
        } catch { return nil }
    }

    deinit { timer?.cancel(); try? handle.close() }

    func record(_ phase: Phase, completed: Int = 0, total: Int = 0, retryCount: Int = 0, code: Int32? = nil) {
        intakeLock.lock()
        guard enqueued < (phase == .failure ? 65 : 64) else { intakeLock.unlock(); return }
        enqueued += 1; intakeLock.unlock()
        queue.async { [self] in
            defer { intakeLock.lock(); enqueued -= 1; intakeLock.unlock() }
            guard !closed else { return }
            let event = Event(phase: phase, at: Date().timeIntervalSince1970,
                completed: max(0, completed), total: max(0, total), retryCount: max(0, retryCount), code: code)
            guard let data = try? JSONEncoder().encode(event) else { return }
            if phase == .failure { saveFailure(data) }
            guard pending.count < 32, pendingBytes + data.count + 1 <= 64 * 1024,
                  written + pendingBytes + data.count + 1 <= Self.sessionLimit else { return }
            pending.append(data + Data([10])); pendingBytes += data.count + 1
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            flush(); closed = true; timer?.cancel(); timer = nil; try? handle.close()
        }
    }

    private func flush() {
        guard !closed, !pending.isEmpty else { return }
        let batch = pending.reduce(into: Data()) { $0.append($1) }
        pending.removeAll(keepingCapacity: true); pendingBytes = 0
        do {
            #if DEBUG
            if failNextFlush { failNextFlush = false; throw CocoaError(.fileWriteOutOfSpace) }
            #endif
            try handle.write(contentsOf: batch); written += batch.count
        }
        catch { closed = true; timer?.cancel(); timer = nil; try? handle.close() }
    }

    private func saveFailure(_ data: Data) {
        // A small failure summary survives detailed-log rotation. It contains
        // no free-text error, path, account, prompt or credential.
        guard data.count < 4000 else { return }
        let url = root.appendingPathComponent("latest-failure.json")
        do {
            try Self.checkOwner(root)
            let exists: Bool
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path); exists = true }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { exists = false }
            if exists {
                guard try Self.regular(url),
                      let old = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      old["format"] as? String == Self.format else { return }
            }
            let event = try JSONSerialization.jsonObject(with: data)
            let bytes = try JSONSerialization.data(withJSONObject: ["format": Self.format, "event": event])
            guard bytes.count <= 4096 else { return }
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Diagnostic failure cannot change business state. */ }
    }

    private static func prepare(_ root: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try checkOwner(root); return }
        // Refuse a pre-existing symlink/directory substitution. Parent support
        // paths are configured by the app, never selected by log contents.
        let parent = root.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            guard try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try marker.write(to: root.appendingPathComponent("owner.marker"), options: .withoutOverwriting)
        try checkOwner(root)
    }

    private static func regular(_ file: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular
    }
    private static func checkOwner(_ root: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
              try regular(root.appendingPathComponent("owner.marker")),
              try Data(contentsOf: root.appendingPathComponent("owner.marker")) == marker else { throw CocoaError(.fileWriteInvalidFileName) }
    }

    static func prune(root: URL, now: Date = Date(), byteLimit: Int = 50 * 1024 * 1024,
                      maxAge: TimeInterval = 30 * 86400) throws {
        try checkOwner(root)
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count <= 4096 else { throw CocoaError(.fileReadTooLarge) }
        var owned: [(URL, Date, Int, UInt64)] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("session-"), name.hasSuffix(".jsonl"),
                  let id = UUID(uuidString: String(name.dropFirst(8).dropLast(6))), try regular(file) else { continue }
            let input = try FileHandle(forReadingFrom: file)
            let first = try input.read(upToCount: 4096) ?? Data(); try input.close()
            guard let line = first.split(separator: 10).first,
                  let header = try? JSONDecoder().decode(Header.self, from: Data(line)),
                  header.format == format, header.attempt == id.uuidString.lowercased() else { continue }
            let attrs = try fm.attributesOfItem(atPath: file.path)
            guard let date = attrs[.modificationDate] as? Date, let bytes = attrs[.size] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber else { continue }
            owned.append((file, date, bytes.intValue, inode.uint64Value))
        }
        var bytes = owned.reduce(0) { $0 + $1.2 }
        // Reserve space for the next session without touching unknown files or
        // the last failure summary, even if somebody placed them in this dir.
        for (file, date, size, inode) in owned.sorted(by: { $0.1 < $1.1 }) {
            guard now.timeIntervalSince(date) > maxAge || bytes > max(0, byteLimit - sessionLimit) else { continue }
            try checkOwner(root)
            let attrs = try fm.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == inode else { continue }
            try fm.removeItem(at: file); bytes -= size
        }
    }
}
