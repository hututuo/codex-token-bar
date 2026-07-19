import Foundation

enum RefreshPerformanceProbe {
    private final class State: @unchecked Sendable {
        var nextID: UInt64 = 1
    }

    struct Trace: Sendable {
        let id: UInt64
        let name: String
        let startedAt: ContinuousClock.Instant

        func mark(_ name: String, metadata: [String: String] = [:]) {
            RefreshPerformanceProbe.mark(trace: self, name: name, metadata: metadata)
        }

        func end(_ status: String = "ok", metadata: [String: String] = [:]) {
            RefreshPerformanceProbe.end(trace: self, status: status, metadata: metadata)
        }
    }

    private static let lock = NSLock()
    private static let state = State()
    private static let clock = ContinuousClock()
    private static let maximumLogBytes: UInt64 = 5 * 1024 * 1024

    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["CODEX_TOKEN_BAR_REFRESH_PROBE"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    static var logURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEX_TOKEN_BAR_REFRESH_PROBE_LOG"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexTokenBar", isDirectory: true)
            .appendingPathComponent("refresh-performance.log")
    }

    static func begin(_ name: String, metadata: [String: String] = [:]) -> Trace? {
        guard isEnabled else { return nil }
        let trace = Trace(id: allocateID(), name: name, startedAt: clock.now)
        write(event: "begin", trace: trace, elapsedMilliseconds: 0, metadata: metadata)
        return trace
    }

    static func mark(trace: Trace?, name: String, metadata: [String: String] = [:]) {
        guard let trace, isEnabled else { return }
        write(event: "mark:\(name)", trace: trace, elapsedMilliseconds: elapsedMilliseconds(since: trace.startedAt), metadata: metadata)
    }

    static func end(trace: Trace?, status: String = "ok", metadata: [String: String] = [:]) {
        guard let trace, isEnabled else { return }
        var metadata = metadata
        metadata["status"] = status
        write(event: "end", trace: trace, elapsedMilliseconds: elapsedMilliseconds(since: trace.startedAt), metadata: metadata)
    }

    static func event(_ name: String, metadata: [String: String] = [:]) {
        guard isEnabled else { return }
        write(event: name, traceID: nil, traceName: nil, elapsedMilliseconds: nil, metadata: metadata)
    }

    private static func allocateID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = state.nextID
        state.nextID &+= 1
        return id
    }

    private static func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Double {
        let duration = startedAt.duration(to: clock.now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func write(
        event: String,
        trace: Trace,
        elapsedMilliseconds: Double?,
        metadata: [String: String]
    ) {
        write(
            event: event,
            traceID: trace.id,
            traceName: trace.name,
            elapsedMilliseconds: elapsedMilliseconds,
            metadata: metadata
        )
    }

    private static func write(
        event: String,
        traceID: UInt64?,
        traceName: String?,
        elapsedMilliseconds: Double?,
        metadata: [String: String]
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields: [String: String] = [
            "time": formatter.string(from: Date()),
            "event": event,
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "main": Thread.isMainThread ? "1" : "0"
        ]
        if let traceID {
            fields["trace"] = String(traceID)
        }
        if let traceName {
            fields["name"] = traceName
        }
        if let elapsedMilliseconds {
            fields["elapsed_ms"] = String(format: "%.2f", elapsedMilliseconds)
        }
        for (key, value) in metadata {
            fields[key] = value
        }
        let line = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(sanitize($0.value))" }
            .joined(separator: " ")
            + "\n"

        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateLogIfNeeded(appendingByteCount: line.utf8.count)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: logURL, options: [.atomic])
            }
        } catch {
            // Performance probes must never affect refresh behavior.
        }
    }

    private static func rotateLogIfNeeded(appendingByteCount: Int) throws {
        guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(max(0, size)) + UInt64(max(0, appendingByteCount)) > maximumLogBytes else {
            return
        }
        let previousURL = logURL.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: previousURL)
        try FileManager.default.moveItem(at: logURL, to: previousURL)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }
}
