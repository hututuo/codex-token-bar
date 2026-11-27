import Foundation

/// Classification evidence for one bounded prefix, independent of ledger ownership.
/// An incomplete prefix must never be treated as evidence for the legacy CLI default.
enum ClaudeTranscriptClassification {
    static let contract = "claude-entrypoint-v2"
    static let fastPathBytes = 64 * 1_024
    static let maximumBytes = 16 * 1_024 * 1_024
    /// Root containers count as one. Keep both decoders below serde_json's default bound.
    static let maximumNestingDepth = 127

    enum IncompleteReason: Equatable {
        case byteLimit
        case partialRecord
        case nestingLimit
    }

    enum Evidence: Equatable {
        /// The end includes the LF committing the first entrypoint-bearing record.
        case explicit(client: UsageClient, recordEnd: Int)
        /// Clean EOF after complete records; a compatibility default, not explicit evidence.
        case legacyCLI
        case incomplete(IncompleteReason)
    }

    struct Result: Equatable {
        let evidence: Evidence
        let bytesRead: Int
        let delimiterBytesExamined: Int

        var client: UsageClient? {
            switch evidence {
            case .explicit(let client, _): client
            case .legacyCLI: .claudeCode
            case .incomplete: nil
            }
        }
    }

    /// This is a candidate classifier. Discovery adoption requires a separate, durable
    /// policy for legacy namespace conflicts and for progress across its total byte budget.
    static func classify(url: URL, byteLimit: Int = maximumBytes) throws -> Result {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try classify(handle: handle, at: url, byteLimit: byteLimit) { count in
            try Task.checkCancellation()
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    /// Keep the physical-witness boundary around the entire classification read.
    /// The injectable reader lets regression tests replace a source at a known chunk.
    static func classify(handle: FileHandle, at url: URL, byteLimit: Int = maximumBytes,
                         read: (Int) throws -> Data) throws -> Result {
        let before = try SourceFileObservation.readPhysical(handle: handle)
        guard before.matches(try SourceFileObservation.read(at: url)) else { throw POSIXError(.ESTALE) }
        let result = try classify(byteLimit: byteLimit, read: read)
        guard before.matches(try SourceFileObservation.readPhysical(handle: handle)),
              before.matches(try SourceFileObservation.read(at: url))
        else { throw POSIXError(.ESTALE) }
        return result
    }

    /// Sequential reads and delimiter inspection are linear in bytes actually returned.
    /// Completed lines are released immediately; only the unfinished line is retained.
    static func classify(byteLimit: Int = maximumBytes, read: (Int) throws -> Data) throws -> Result {
        let limit = min(maximumBytes, max(0, byteLimit))
        var bytesRead = 0
        var examined = 0
        var line = Data()
        var depth = 0
        var inString = false
        var escaped = false
        while bytesRead < limit {
            let chunkSize = bytesRead < fastPathBytes ? min(4 * 1_024, fastPathBytes - bytesRead) : fastPathBytes
            let requested = min(chunkSize, limit - bytesRead)
            let chunk = try read(requested)
            guard chunk.count <= requested else { throw CocoaError(.fileReadUnknown) }
            if chunk.isEmpty {
                return Result(evidence: line.isEmpty ? .legacyCLI : .incomplete(.partialRecord),
                              bytesRead: bytesRead, delimiterBytesExamined: examined)
            }
            let offset = bytesRead
            bytesRead += chunk.count
            var segment = chunk.startIndex
            for index in chunk.indices {
                examined += 1
                let byte = chunk[index]
                if byte != 0x0A {
                    if inString {
                        if escaped { escaped = false }
                        else if byte == 0x5C { escaped = true }
                        else if byte == 0x22 { inString = false }
                    } else if byte == 0x22 {
                        inString = true
                    } else if byte == 0x7B || byte == 0x5B {
                        depth += 1
                        if depth > maximumNestingDepth {
                            return Result(evidence: .incomplete(.nestingLimit), bytesRead: bytesRead,
                                          delimiterBytesExamined: examined)
                        }
                    } else if byte == 0x7D || byte == 0x5D {
                        depth = max(0, depth - 1)
                    }
                    continue
                }
                line.append(chunk[segment..<index])
                if let client = source(inCompleteLine: line) {
                    let end = offset + chunk.distance(from: chunk.startIndex, to: index) + 1
                    return Result(evidence: .explicit(client: client, recordEnd: end),
                                  bytesRead: bytesRead, delimiterBytesExamined: examined)
                }
                line.removeAll(keepingCapacity: true)
                depth = 0
                inString = false
                escaped = false
                segment = chunk.index(after: index)
            }
            line.append(chunk[segment..<chunk.endIndex])
        }
        return Result(evidence: .incomplete(.byteLimit), bytesRead: bytesRead, delimiterBytesExamined: examined)
    }

    private static func source(inCompleteLine rawLine: Data) -> UsageClient? {
        autoreleasepool {
            var line = rawLine
            if line.last == 0x0D { line.removeLast() }
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let entrypoint = object["entrypoint"] as? String,
                  !entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return entrypoint.hasPrefix("claude-desktop") ? .claudeDesktop : .claudeCode
        }
    }
}
