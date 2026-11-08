import Foundation
import Darwin

/// Bounded asynchronous diagnostics. Failures are swallowed and never change a
/// business result. One file per process preserves the previous launch.
public final class DiagnosticJournal: @unchecked Sendable {
    public let session = UUID().uuidString.lowercased()
    private let root: URL
    private let version: String
    private let build: String
    private let queue = DispatchQueue(label: "TokenBar.diagnostic-journal", qos: .utility)
    private let intake = NSLock()
    private var queued = 0
    private var sequence: Int64 = 0
    private var written = 0
    private var segment = 0
    private var handle: FileHandle?
    private var disabled = false
    private var lastProgress: [DiagnosticArea: TimeInterval] = [:]
    public init(root: URL, version: String, build: String) { self.root = root; self.version = version; self.build = build }
    deinit { try? handle?.close() }

    public func record(_ area: DiagnosticArea, _ phase: DiagnosticPhase, metrics: [String: Int64] = [:],
                       attempt: String? = nil, targetVersion: String? = nil, targetBuild: String? = nil) {
        intake.lock()
        guard queued < 128 else { intake.unlock(); return }
        queued += 1; intake.unlock()
        let at = Date().timeIntervalSince1970
        queue.async { [self] in
            defer { intake.lock(); queued -= 1; intake.unlock() }
            if phase == .progress {
                guard at - (lastProgress[area] ?? 0) >= 1 else { return }
                lastProgress[area] = at
            }
            guard !disabled else { return }
            do {
                if handle == nil {
                    try DiagnosticFiles.ownedDirectory(root)
                    try prune()
                    let fd = try DiagnosticFiles.open(root.appendingPathComponent("events-\(session)-\(segment).jsonl"), flags: O_WRONLY | O_CREAT | O_EXCL)
                    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                }
                sequence += 1
                let row = DiagnosticEvent(session: session, sequence: sequence, area: area, phase: phase, version: version, build: build,
                    metrics: metrics, attempt: attempt, targetVersion: targetVersion, targetBuild: targetBuild, at: Int64(at * 1000))
                let data = try JSONEncoder().encode(row) + Data([10])
                if phase == .failed {
                    let last = root.appendingPathComponent("failure-\(session).json")
                    try? DiagnosticFiles.create(last, data: data)
                }
                if written + data.count > 256 * 1024 {
                    try handle?.close();handle=nil;segment += 1;written=0
                    try prune()
                    let fd=try DiagnosticFiles.open(root.appendingPathComponent("events-\(session)-\(segment).jsonl"),flags:O_WRONLY|O_CREAT|O_EXCL)
                    handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
                }
                try handle?.write(contentsOf: data); written += data.count
            } catch { disabled = true; try? handle?.close(); handle = nil }
        }
    }
    @discardableResult public func flush(timeout: TimeInterval = 1) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
    private func prune() throws {
        let fm = FileManager.default
        let files = try DiagnosticFiles.files(root, prefix: "", suffix: "").filter {
            let name = $0.lastPathComponent
            return (name.hasPrefix("events-") && name.hasSuffix(".jsonl")) || (name.hasPrefix("failure-") && name.hasSuffix(".json"))
        }
        var records: [(URL, Date, Int)] = []
        for file in files {
            guard let bytes = try? DiagnosticFiles.read(file), let first = bytes.split(separator: 10).first,
                  DiagnosticEvent.sanitized(Data(first)) != nil,
                  let attrs = try? fm.attributesOfItem(atPath: file.path), let date = attrs[.modificationDate] as? Date else { continue }
            records.append((file, date, bytes.count))
        }
        var total = records.reduce(0) { $0 + $1.2 }
        var count = records.count
        for (file, date, size) in records.sorted(by: { $0.1 < $1.1 }) {
            if Date().timeIntervalSince(date) > 30 * 86400 || total > 8 * 1024 * 1024 || count > 120 {
                try? fm.removeItem(at: file); total -= size; count -= 1
            }
        }
    }
}
