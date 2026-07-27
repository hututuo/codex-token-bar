import Darwin
import Foundation

enum CodexCompletedRolloutLine {
    case memory(Data)
    case mapped(CodexMappedRolloutLine)

    var isEmpty: Bool {
        switch self {
        case .memory(let data):
            return data.isEmpty
        case .mapped(let line):
            return line.count == 0
        }
    }
}

final class CodexRolloutLineAccumulator {
    // 这是内存/磁盘切换点，不是产品数据上限。超过后继续完整接收、解析和导出。
    static let inMemoryByteThreshold = 1024 * 1024

    private var memory = Data()
    private var spill: CodexAnonymousRolloutSpill?

    var isEmpty: Bool {
        memory.isEmpty && spill == nil
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        if let spill {
            try spill.append(data)
            return
        }
        let remainingMemoryCapacity = max(
            0,
            Self.inMemoryByteThreshold - memory.count
        )
        if data.count <= remainingMemoryCapacity {
            memory.append(data)
            return
        }
        let spill = try CodexAnonymousRolloutSpill()
        if !memory.isEmpty {
            try spill.append(memory)
        }
        memory.removeAll(keepingCapacity: false)
        try spill.append(data)
        self.spill = spill
    }

    func finish() throws -> CodexCompletedRolloutLine {
        if let spill {
            self.spill = nil
            return .mapped(try spill.finish())
        }
        let result = memory
        memory.removeAll(keepingCapacity: true)
        return .memory(result)
    }
}

private final class CodexAnonymousRolloutSpill {
    private var descriptor: Int32

    init() throws {
        var template = Array(
            "\(NSTemporaryDirectory())codex-token-bar-rollout-line.XXXXXX".utf8CString
        )
        descriptor = template.withUnsafeMutableBufferPointer { pointer in
            mkstemp(pointer.baseAddress)
        }
        guard descriptor >= 0 else {
            throw CodexRolloutStreamingError.temporaryFile(
                String(cString: strerror(errno))
            )
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let detail = String(cString: strerror(errno))
            _ = template.withUnsafeBufferPointer { pointer in
                Darwin.unlink(pointer.baseAddress)
            }
            Darwin.close(descriptor)
            descriptor = -1
            throw CodexRolloutStreamingError.temporaryFile(detail)
        }
        // 映射和读取都通过仍打开的 fd；立刻 unlink，进程异常退出也不遗留正文。
        let unlinkResult = template.withUnsafeBufferPointer { pointer in
            Darwin.unlink(pointer.baseAddress)
        }
        guard unlinkResult == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw CodexRolloutStreamingError.temporaryFile(detail)
        }
    }

    func append(_ data: Data) throws {
        guard descriptor >= 0 else {
            throw CodexRolloutStreamingError.temporaryFile("临时文件已关闭")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw CodexRolloutStreamingError.temporaryFile(
                        String(cString: strerror(errno))
                    )
                }
            }
        }
    }

    func finish() throws -> CodexMappedRolloutLine {
        guard descriptor >= 0 else {
            throw CodexRolloutStreamingError.temporaryFile("临时文件已关闭")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Int.max) else {
            throw CodexRolloutStreamingError.temporaryFile(
                String(cString: strerror(errno))
            )
        }
        let count = Int(metadata.st_size)
        guard count > 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            return CodexMappedRolloutLine.empty
        }
        let mapping = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard mapping != MAP_FAILED, let mapping else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw CodexRolloutStreamingError.temporaryFile(detail)
        }
        Darwin.close(descriptor)
        descriptor = -1
        return CodexMappedRolloutLine(mapping: mapping, count: count)
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}

final class CodexMappedRolloutLine: @unchecked Sendable {
    static let empty = CodexMappedRolloutLine(mapping: nil, count: 0)

    private let mapping: UnsafeMutableRawPointer?
    let count: Int

    fileprivate init(mapping: UnsafeMutableRawPointer?, count: Int) {
        self.mapping = mapping
        self.count = count
    }

    subscript(index: Int) -> UInt8 {
        precondition(index >= 0 && index < count)
        return mapping!.load(fromByteOffset: index, as: UInt8.self)
    }

    func copiedData(in range: Range<Int>) -> Data {
        guard !range.isEmpty else { return Data() }
        return Data(
            bytes: mapping!.advanced(by: range.lowerBound),
            count: range.count
        )
    }

    deinit {
        if let mapping, count > 0 {
            munmap(mapping, count)
        }
    }
}

struct CodexLargeRolloutMessage {
    let speaker: String
    let timestamp: String?

    private let line: CodexMappedRolloutLine
    private let blocks: [PreparedBlock]

    static func parse(_ line: CodexMappedRolloutLine) throws -> Self? {
        guard let plan = try CodexLargeRolloutJSONParser(line: line).parseMessage(),
              plan.eventType == "response_item",
              plan.payloadType == "message",
              plan.role == "user" || plan.role == "assistant" else {
            return nil
        }
        do {
            let blocks = try plan.blocks.compactMap { block -> PreparedBlock? in
                switch block.type {
                case "input_text", "output_text":
                    guard let token = block.text else { return nil }
                    let metrics = try CodexJSONStringChunkIterator.metrics(
                        line: line,
                        token: token
                    )
                    guard let lineStart = metrics.firstNonNewline,
                          let lineEnd = metrics.endAfterLastNonNewline,
                          metrics.firstNonWhitespace != nil else {
                        return nil
                    }
                    return .text(
                        token: token,
                        lineRange: lineStart..<lineEnd,
                        firstNonWhitespace: metrics.firstNonWhitespace!,
                        endAfterLastNonWhitespace: metrics.endAfterLastNonWhitespace!
                    )
                case "input_image":
                    guard let token = block.imageURL else {
                        return .literal("> Image attachment")
                    }
                    let metrics = try CodexJSONStringChunkIterator.metrics(
                        line: line,
                        token: token
                    )
                    guard let start = metrics.firstNonWhitespace,
                          let end = metrics.endAfterLastNonWhitespace else {
                        return .literal("> Image attachment")
                    }
                    let trimmedRange = start..<end
                    if try CodexJSONStringChunkIterator.decodedPrefix(
                        line: line,
                        token: token,
                        range: trimmedRange,
                        count: 5
                    ) == Data("data:".utf8) {
                        return .literal("> Image attachment")
                    }
                    return .imageLink(token: token, range: trimmedRange)
                default:
                    return nil
                }
            }
            guard !blocks.isEmpty else { return nil }
            return Self(
                speaker: plan.role == "user" ? "User" : "Assistant",
                timestamp: plan.timestamp,
                line: line,
                blocks: blocks
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            // 与小行 JSONSerialization 路径一致：损坏/半写入行跳过，不中断导出。
            return nil
        }
    }

    func emitBody(_ emit: CodexMarkdownChunkEmitter) async throws {
        for index in blocks.indices {
            try Task.checkCancellation()
            if index > 0 {
                try await emit("\n\n")
            }
            switch blocks[index] {
            case .literal(let text):
                try await emit(text)
            case .imageLink(let token, let range):
                try await emit("> Image attachment\n[Image link](<")
                try await CodexJSONStringChunkIterator.emit(
                    line: line,
                    token: token,
                    range: range,
                    emit: emit
                )
                try await emit(">)")
            case let .text(
                token,
                lineRange,
                firstNonWhitespace,
                endAfterLastNonWhitespace
            ):
                let start = index == blocks.startIndex
                    ? firstNonWhitespace
                    : lineRange.lowerBound
                let end = index == blocks.index(before: blocks.endIndex)
                    ? endAfterLastNonWhitespace
                    : lineRange.upperBound
                try await CodexJSONStringChunkIterator.emit(
                    line: line,
                    token: token,
                    range: start..<end,
                    emit: emit
                )
            }
        }
    }

    private enum PreparedBlock {
        case literal(String)
        case imageLink(token: CodexJSONStringToken, range: Range<Int>)
        case text(
            token: CodexJSONStringToken,
            lineRange: Range<Int>,
            firstNonWhitespace: Int,
            endAfterLastNonWhitespace: Int
        )
    }
}

private struct CodexLargeRolloutMessagePlan {
    var eventType: String?
    var timestamp: String?
    var payloadType: String?
    var role: String?
    var blocks: [CodexLargeRolloutBlockPlan] = []
}

private struct CodexLargeRolloutBlockPlan {
    var type: String?
    var text: CodexJSONStringToken?
    var imageURL: CodexJSONStringToken?
}

private struct CodexJSONStringToken {
    let fullRange: Range<Int>
    let contentRange: Range<Int>
}

private final class CodexLargeRolloutJSONParser {
    private static let cancellationCheckInterval = 1024 * 1024

    private let line: CodexMappedRolloutLine
    private var index = 0
    private var nextCancellationCheck = 0

    init(line: CodexMappedRolloutLine) {
        self.line = line
    }

    func parseMessage() throws -> CodexLargeRolloutMessagePlan? {
        var plan = CodexLargeRolloutMessagePlan()
        guard try parseObject({ key in
            switch key {
            case "type":
                plan.eventType = try parseSmallStringValue()
                return plan.eventType != nil
            case "timestamp":
                if try currentAfterSkippingWhitespace() == 0x22 {
                    plan.timestamp = try parseSmallStringValue()
                    return plan.timestamp != nil
                }
                plan.timestamp = nil
                return try skipValue()
            case "payload":
                guard let payload = try parsePayload() else { return false }
                plan.payloadType = payload.payloadType
                plan.role = payload.role
                plan.blocks = payload.blocks
                return true
            default:
                return try skipValue()
            }
        }) else {
            return nil
        }
        try skipWhitespace()
        return index == line.count ? plan : nil
    }

    private func parsePayload() throws -> (
        payloadType: String?,
        role: String?,
        blocks: [CodexLargeRolloutBlockPlan]
    )? {
        var payloadType: String?
        var role: String?
        var blocks: [CodexLargeRolloutBlockPlan] = []
        guard try parseObject({ key in
            switch key {
            case "type":
                payloadType = try parseSmallStringValue()
                return payloadType != nil
            case "role":
                role = try parseSmallStringValue()
                return role != nil
            case "content":
                guard let parsed = try parseContentArray() else { return false }
                blocks = parsed
                return true
            default:
                return try skipValue()
            }
        }) else {
            return nil
        }
        return (payloadType, role, blocks)
    }

    private func parseContentArray() throws -> [CodexLargeRolloutBlockPlan]? {
        try skipWhitespace()
        guard consume(0x5B) else { return nil } // [
        var blocks: [CodexLargeRolloutBlockPlan] = []
        try skipWhitespace()
        if consume(0x5D) { return blocks } // ]
        while true {
            try checkCancellationIfNeeded()
            try skipWhitespace()
            if current == 0x7B { // {
                guard let block = try parseContentBlock() else { return nil }
                blocks.append(block)
            } else if try !skipValue() {
                return nil
            }
            try skipWhitespace()
            if consume(0x5D) { return blocks }
            guard consume(0x2C) else { return nil } // ,
        }
    }

    private func parseContentBlock() throws -> CodexLargeRolloutBlockPlan? {
        var block = CodexLargeRolloutBlockPlan()
        guard try parseObject({ key in
            switch key {
            case "type":
                block.type = try parseSmallStringValue()
                return block.type != nil
            case "text":
                if try currentAfterSkippingWhitespace() == 0x22 {
                    block.text = try parseStringToken()
                    return block.text != nil
                }
                block.text = nil
                return try skipValue()
            case "image_url":
                if try currentAfterSkippingWhitespace() == 0x22 {
                    block.imageURL = try parseStringToken()
                    return block.imageURL != nil
                }
                block.imageURL = nil
                return try skipValue()
            default:
                return try skipValue()
            }
        }) else {
            return nil
        }
        return block
    }

    private func parseObject(
        _ parseField: (String?) throws -> Bool
    ) throws -> Bool {
        try skipWhitespace()
        guard consume(0x7B) else { return false } // {
        try skipWhitespace()
        if consume(0x7D) { return true } // }
        while true {
            try checkCancellationIfNeeded()
            guard let token = try parseStringToken() else { return false }
            let key = decodeSmallString(token, maximumBytes: 1024)
            try skipWhitespace()
            guard consume(0x3A), try parseField(key) else { return false } // :
            try skipWhitespace()
            if consume(0x7D) { return true }
            guard consume(0x2C) else { return false } // ,
            try skipWhitespace()
        }
    }

    private func parseSmallStringValue() throws -> String? {
        guard let token = try parseStringToken() else { return nil }
        return decodeSmallString(token, maximumBytes: 64 * 1024)
    }

    private func decodeSmallString(
        _ token: CodexJSONStringToken,
        maximumBytes: Int
    ) -> String? {
        guard token.fullRange.count <= maximumBytes else { return nil }
        return (try? JSONSerialization.jsonObject(
            with: line.copiedData(in: token.fullRange),
            options: [.fragmentsAllowed]
        )) as? String
    }

    private func parseStringToken() throws -> CodexJSONStringToken? {
        try skipWhitespace()
        guard current == 0x22 else { return nil } // "
        let fullStart = index
        index += 1
        let contentStart = index
        while index < line.count {
            try checkCancellationIfNeeded()
            let byte = line[index]
            if byte == 0x22 {
                let contentEnd = index
                index += 1
                return CodexJSONStringToken(
                    fullRange: fullStart..<index,
                    contentRange: contentStart..<contentEnd
                )
            }
            if byte == 0x5C { // \
                index += 1
                guard index < line.count else { return nil }
                let escape = line[index]
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x75]
                    .contains(escape) else {
                    return nil
                }
                index += 1
                if escape == 0x75 {
                    guard index + 4 <= line.count else { return nil }
                    for position in index..<(index + 4)
                    where Self.hexValue(line[position]) == nil {
                        return nil
                    }
                    index += 4
                }
                continue
            }
            guard byte >= 0x20 else { return nil }
            index += 1
        }
        return nil
    }

    private func skipValue() throws -> Bool {
        try skipWhitespace()
        guard let first = current else { return false }
        if first == 0x22 {
            return try parseStringToken() != nil
        }
        if first == 0x7B || first == 0x5B { // { [
            var depth = 0
            while index < line.count {
                try checkCancellationIfNeeded()
                let byte = line[index]
                if byte == 0x22 {
                    guard try parseStringToken() != nil else { return false }
                    continue
                }
                index += 1
                if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 { return true }
                    if depth < 0 { return false }
                }
            }
            return false
        }
        let start = index
        while let byte = current,
              byte != 0x2C,
              byte != 0x7D,
              byte != 0x5D,
              !Self.isWhitespace(byte) {
            try checkCancellationIfNeeded()
            index += 1
        }
        return index > start
    }

    private var current: UInt8? {
        index < line.count ? line[index] : nil
    }

    private func currentAfterSkippingWhitespace() throws -> UInt8? {
        try skipWhitespace()
        return current
    }

    private func skipWhitespace() throws {
        while let byte = current, Self.isWhitespace(byte) {
            try checkCancellationIfNeeded()
            index += 1
        }
    }

    private func checkCancellationIfNeeded() throws {
        guard index >= nextCancellationCheck else { return }
        try Task.checkCancellation()
        let (next, overflow) = index.addingReportingOverflow(
            Self.cancellationCheckInterval
        )
        nextCancellationCheck = overflow ? Int.max : next
    }

    private func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    fileprivate static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }
}

private struct CodexDecodedStringMetrics {
    var firstNonNewline: Int?
    var endAfterLastNonNewline: Int?
    var firstNonWhitespace: Int?
    var endAfterLastNonWhitespace: Int?
}

private struct CodexJSONStringChunkIterator {
    private static let chunkBytes = 64 * 1024

    private let line: CodexMappedRolloutLine
    private let token: CodexJSONStringToken
    private var rawIndex: Int
    private var decodedOffset = 0
    private var pendingCarriageReturn = false
    private var pendingScalar: UInt32?
    private var finished = false

    init(line: CodexMappedRolloutLine, token: CodexJSONStringToken) {
        self.line = line
        self.token = token
        rawIndex = token.contentRange.lowerBound
    }

    mutating func next() throws -> (offset: Int, data: Data)? {
        guard !finished else { return nil }
        try Task.checkCancellation()
        let start = decodedOffset
        var data = Data()
        data.reserveCapacity(Self.chunkBytes + 4)
        while data.count < Self.chunkBytes {
            guard let scalar = try nextNormalizedScalar() else {
                finished = true
                break
            }
            Self.appendUTF8(scalar, to: &data)
        }
        guard !data.isEmpty else { return nil }
        decodedOffset += data.count
        return (start, data)
    }

    private mutating func nextNormalizedScalar() throws -> UInt32? {
        if let pendingScalar {
            self.pendingScalar = nil
            if pendingScalar == 0x0D {
                pendingCarriageReturn = true
                return try nextNormalizedScalar()
            }
            return pendingScalar
        }
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if let next = try nextDecodedScalar() {
                if next != 0x0A {
                    pendingScalar = next
                }
            }
            return 0x0A
        }
        guard let scalar = try nextDecodedScalar() else { return nil }
        if scalar == 0x0D {
            pendingCarriageReturn = true
            return try nextNormalizedScalar()
        }
        return scalar
    }

    private mutating func nextDecodedScalar() throws -> UInt32? {
        guard rawIndex < token.contentRange.upperBound else { return nil }
        let first = line[rawIndex]
        rawIndex += 1
        if first == 0x5C { // \
            guard rawIndex < token.contentRange.upperBound else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
            let escape = line[rawIndex]
            rawIndex += 1
            switch escape {
            case 0x22: return 0x22
            case 0x5C: return 0x5C
            case 0x2F: return 0x2F
            case 0x62: return 0x08
            case 0x66: return 0x0C
            case 0x6E: return 0x0A
            case 0x72: return 0x0D
            case 0x74: return 0x09
            case 0x75:
                let firstUnit = try readHexQuad()
                if (0xD800...0xDBFF).contains(firstUnit) {
                    guard rawIndex + 2 <= token.contentRange.upperBound,
                          line[rawIndex] == 0x5C,
                          line[rawIndex + 1] == 0x75 else {
                        throw CodexRolloutStreamingError.invalidJSONString
                    }
                    rawIndex += 2
                    let secondUnit = try readHexQuad()
                    guard (0xDC00...0xDFFF).contains(secondUnit) else {
                        throw CodexRolloutStreamingError.invalidJSONString
                    }
                    return 0x10000
                        + ((firstUnit - 0xD800) << 10)
                        + (secondUnit - 0xDC00)
                }
                guard !(0xDC00...0xDFFF).contains(firstUnit) else {
                    throw CodexRolloutStreamingError.invalidJSONString
                }
                return firstUnit
            default:
                throw CodexRolloutStreamingError.invalidJSONString
            }
        }
        guard first >= 0x20 else {
            throw CodexRolloutStreamingError.invalidJSONString
        }
        if first < 0x80 { return UInt32(first) }

        let length: Int
        var value: UInt32
        switch first {
        case 0xC2...0xDF:
            length = 2
            value = UInt32(first & 0x1F)
        case 0xE0...0xEF:
            length = 3
            value = UInt32(first & 0x0F)
        case 0xF0...0xF4:
            length = 4
            value = UInt32(first & 0x07)
        default:
            throw CodexRolloutStreamingError.invalidJSONString
        }
        var continuationBytes: [UInt8] = []
        continuationBytes.reserveCapacity(length - 1)
        for _ in 1..<length {
            guard rawIndex < token.contentRange.upperBound else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
            let byte = line[rawIndex]
            rawIndex += 1
            guard byte & 0xC0 == 0x80 else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
            continuationBytes.append(byte)
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        if length == 3 {
            let second = continuationBytes[0]
            guard !(first == 0xE0 && second < 0xA0),
                  !(first == 0xED && second >= 0xA0) else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
        } else if length == 4 {
            let second = continuationBytes[0]
            guard !(first == 0xF0 && second < 0x90),
                  !(first == 0xF4 && second >= 0x90) else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
        }
        guard value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else {
            throw CodexRolloutStreamingError.invalidJSONString
        }
        return value
    }

    private mutating func readHexQuad() throws -> UInt32 {
        guard rawIndex + 4 <= token.contentRange.upperBound else {
            throw CodexRolloutStreamingError.invalidJSONString
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = CodexLargeRolloutJSONParser.hexValue(line[rawIndex]) else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
            rawIndex += 1
            value = (value << 4) | digit
        }
        return value
    }

    static func metrics(
        line: CodexMappedRolloutLine,
        token: CodexJSONStringToken
    ) throws -> CodexDecodedStringMetrics {
        var iterator = Self(line: line, token: token)
        var metrics = CodexDecodedStringMetrics()
        while let chunk = try iterator.next() {
            let text = String(decoding: chunk.data, as: UTF8.self)
            var byteOffset = chunk.offset
            for scalar in text.unicodeScalars {
                let length = scalar.utf8.count
                let end = byteOffset + length
                if !CharacterSet.newlines.contains(scalar) {
                    if metrics.firstNonNewline == nil {
                        metrics.firstNonNewline = byteOffset
                    }
                    metrics.endAfterLastNonNewline = end
                }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if metrics.firstNonWhitespace == nil {
                        metrics.firstNonWhitespace = byteOffset
                    }
                    metrics.endAfterLastNonWhitespace = end
                }
                byteOffset = end
            }
        }
        return metrics
    }

    static func decodedPrefix(
        line: CodexMappedRolloutLine,
        token: CodexJSONStringToken,
        range: Range<Int>,
        count: Int
    ) throws -> Data {
        var iterator = Self(line: line, token: token)
        var result = Data()
        while result.count < count, let chunk = try iterator.next() {
            let chunkRange = chunk.offset..<(chunk.offset + chunk.data.count)
            guard let intersection = chunkRange.intersection(range) else { continue }
            let localStart = intersection.lowerBound - chunk.offset
            let available = min(
                intersection.count,
                count - result.count
            )
            result.append(chunk.data[localStart..<(localStart + available)])
        }
        return result
    }

    static func emit(
        line: CodexMappedRolloutLine,
        token: CodexJSONStringToken,
        range: Range<Int>,
        emit: CodexMarkdownChunkEmitter
    ) async throws {
        var iterator = Self(line: line, token: token)
        while let chunk = try iterator.next() {
            let chunkRange = chunk.offset..<(chunk.offset + chunk.data.count)
            guard let intersection = chunkRange.intersection(range) else {
                if chunkRange.lowerBound >= range.upperBound { return }
                continue
            }
            let localStart = intersection.lowerBound - chunk.offset
            let localEnd = intersection.upperBound - chunk.offset
            guard let text = String(
                data: chunk.data[localStart..<localEnd],
                encoding: .utf8
            ) else {
                throw CodexRolloutStreamingError.invalidJSONString
            }
            try await emit(text)
        }
    }

    private static func appendUTF8(_ scalar: UInt32, to data: inout Data) {
        switch scalar {
        case 0...0x7F:
            data.append(UInt8(scalar))
        case 0x80...0x7FF:
            data.append(UInt8(0xC0 | (scalar >> 6)))
            data.append(UInt8(0x80 | (scalar & 0x3F)))
        case 0x800...0xFFFF:
            data.append(UInt8(0xE0 | (scalar >> 12)))
            data.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            data.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            data.append(UInt8(0xF0 | (scalar >> 18)))
            data.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            data.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            data.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}

extension Range where Bound == Int {
    fileprivate func intersection(_ other: Range<Int>) -> Range<Int>? {
        let lower = Swift.max(lowerBound, other.lowerBound)
        let upper = Swift.min(upperBound, other.upperBound)
        return lower < upper ? lower..<upper : nil
    }
}

private enum CodexRolloutStreamingError: LocalizedError {
    case invalidJSONString
    case temporaryFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSONString:
            return "rollout JSON 字符串无效"
        case .temporaryFile(let detail):
            return "无法创建或读取 rollout 流式临时文件：\(detail)"
        }
    }
}
