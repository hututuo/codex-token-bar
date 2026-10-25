import Foundation

/// Decodes the protobuf blobs of an Antigravity conversation database (METRICS 4.8). Blobs are borrowed for the
/// duration of a call only. An empty blob is a valid empty message, so nothing is ever `.blank`.
enum AntigravityBlobs {
    /// A token field above this makes its step malformed.
    static let maxTokens: UInt64 = 10_000_000

    /// `CortexStepMetadata` of `steps.metadata`.
    static func stepMetadata(_ blob: UnsafeRawBufferPointer) -> LineExtraction<AntigravityStepMetadata> {
        extraction(try? step(blob))
    }

    /// `CortexStepGeneratorMetadata` of `gen_metadata.data`.
    static func generation(_ blob: UnsafeRawBufferPointer) -> LineExtraction<AntigravityGeneration> {
        extraction(try? generationMetadata(blob))
    }

    /// `ExecutorMetadata` of `executor_metadata.data`.
    static func executor(_ blob: UnsafeRawBufferPointer) -> LineExtraction<AntigravityExecutor> {
        extraction(try? executorMetadata(blob))
    }

    /// `CortexTrajectoryMetadata` of `trajectory_metadata_blob.data`.
    static func trajectory(_ blob: UnsafeRawBufferPointer) -> LineExtraction<AntigravityTrajectory> {
        extraction(try? trajectoryMetadata(blob))
    }

    /// Basename of a path or URI (METRICS 4.8 Metadata). A scheme of two or more characters is removed together with
    /// the authority (`//host`), and the rest is percent-decoded as UTF-8 (invalid escapes stay as they are) before
    /// splitting on `/` and `\`. Nil when no component is left.
    static func uriBasename(_ value: String) -> String? {
        var bytes = Array(value.utf8)
        if let colon = schemeEnd(bytes) {
            var rest = bytes[(colon + 1)...]
            if rest.starts(with: [slash, slash]) {
                rest = rest.dropFirst(2).firstIndex(of: slash).map { rest[$0...] } ?? []
            }
            bytes = percentDecoded(rest)
        }
        return lastComponent(bytes)
    }

    /// The percent-decoded path of a `file:` URI with an empty or `localhost` authority, without trailing slashes.
    /// Nil for any other value.
    static func filePath(ofURI value: String) -> String? {
        let bytes = Array(value.utf8)
        guard let colon = schemeEnd(bytes), bytes[..<colon].map({ $0 | 0x20 }).elementsEqual("file".utf8) else { return nil }
        var rest = bytes[(colon + 1)...]
        if rest.starts(with: [slash, slash]) {
            rest = rest.dropFirst(2)
            let end = rest.firstIndex(of: slash) ?? rest.endIndex
            let host = rest[..<end].map { $0 | 0x20 }
            guard host.isEmpty || host.elementsEqual("localhost".utf8) else { return nil }
            rest = rest[end...]
        }
        var path = percentDecoded(rest)
        while path.count > 1, path.last == slash { path.removeLast() }
        guard path.first == slash else { return nil }
        return String(decoding: path, as: UTF8.self)
    }

    // MARK: - Messages

    private static func extraction<Value>(_ value: Value?) -> LineExtraction<Value> {
        value.map { .line($0) } ?? .malformed
    }

    /// Nil when a token count is implausible.
    private static func step(_ blob: UnsafeRawBufferPointer) throws(ProtobufError) -> AntigravityStepMetadata? {
        let message = try ProtobufMessage(blob)
        var step = AntigravityStepMetadata()
        step.createdMs = try message.timestampMs(1)
        step.viewableMs = try message.timestampMs(6)
        step.finishedGeneratingMs = try message.timestampMs(7)
        step.completedMs = try message.timestampMs(8)
        step.lastCompletedChunkMs = try message.timestampMs(22)
        step.startedMs = try message.timestampMs(32)
        if let usage = try message.message(9) {
            let input = usage.uint(2), output = usage.uint(3), cacheRead = usage.uint(5)
            let thinking = usage.uint(9), response = usage.uint(10)
            guard input <= maxTokens, output <= maxTokens, cacheRead <= maxTokens, thinking <= maxTokens,
                  response <= maxTokens else { return nil }
            step.usage = AntigravityUsage(
                input: Int64(input), output: Int64(output), cacheRead: Int64(cacheRead), thinking: Int64(thinking),
                response: Int64(response), key: nonEmpty(usage.string(11)) ?? nonEmpty(usage.string(7))
            )
        }
        return step
    }

    private static func generationMetadata(_ blob: UnsafeRawBufferPointer) throws(ProtobufError) -> AntigravityGeneration {
        let message = try ProtobufMessage(blob)
        let chat = try message.message(1)
        var generation = AntigravityGeneration(stepIndices: Set(try message.repeatedUInt(2)))
        if let chat {
            generation.model = nonEmpty(chat.string(19)) ?? nonEmpty(chat.string(21))
        }
        return generation
    }

    private static func executorMetadata(_ blob: UnsafeRawBufferPointer) throws(ProtobufError) -> AntigravityExecutor {
        let message = try ProtobufMessage(blob)
        let planner = try message.message(10)?.message(1)
        return AntigravityExecutor(
            terminationReason: message.int(1),
            lastStepIdx: message.int(3),
            model: planner.flatMap { nonEmpty($0.string(28)) }
        )
    }

    private static func trajectoryMetadata(_ blob: UnsafeRawBufferPointer) throws(ProtobufError) -> AntigravityTrajectory {
        let message = try ProtobufMessage(blob)
        let workspace = try message.message(1, first: true)
        var trajectory = AntigravityTrajectory()
        trajectory.createdMs = try message.timestampMs(2)
        if let field = message.first(7, wire: .lengthDelimited) {
            let uri = String(decoding: field.payload, as: UTF8.self)
            trajectory.project = uriBasename(uri)
            if trajectory.project != nil { trajectory.cwdPath = filePath(ofURI: uri) }
        }
        if trajectory.project == nil, let workspace {
            let uri = workspace.string(1)
            trajectory.project = uriBasename(uri)
            if trajectory.project != nil { trajectory.cwdPath = filePath(ofURI: uri) }
        }
        trajectory.parentConversationId = nonEmpty(message.string(5))
        trajectory.isSubagent = trajectory.parentConversationId != nil || message.int(17) > 0
            || message.last(8, wire: .lengthDelimited) != nil
        return trajectory
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    // MARK: - URIs

    private static let slash = UInt8(ascii: "/")
    private static let backslash = UInt8(ascii: "\\")
    private static let percent = UInt8(ascii: "%")

    /// Index of the colon that ends a leading `[A-Za-z][A-Za-z0-9+.-]+:` scheme.
    private static func schemeEnd(_ bytes: [UInt8]) -> Int? {
        guard let first = bytes.first, isLetter(first) else { return nil }
        var index = 1
        while index < bytes.count, isSchemeCharacter(bytes[index]) { index += 1 }
        guard index >= 2, index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        return index
    }

    /// `%XX` with two hexadecimal digits becomes that byte; any other `%` stays literal.
    private static func percentDecoded(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == percent, index + 2 < bytes.endIndex,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    /// The last non-empty component between `/` and `\` separators, decoded as UTF-8 with U+FFFD for invalid bytes.
    /// Decoding a component alone equals decoding the whole path, since no invalid sequence ever absorbs ASCII.
    private static func lastComponent(_ bytes: [UInt8]) -> String? {
        var end = bytes.count
        while end > 0, bytes[end - 1] == slash || bytes[end - 1] == backslash { end -= 1 }
        guard end > 0 else { return nil }
        var start = end
        while start > 0, bytes[start - 1] != slash, bytes[start - 1] != backslash { start -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    private static func isSchemeCharacter(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        if isDigit(byte) { return byte - UInt8(ascii: "0") }
        let lower = byte | 0x20
        return (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(lower) ? lower - UInt8(ascii: "a") + 10 : nil
    }
}
