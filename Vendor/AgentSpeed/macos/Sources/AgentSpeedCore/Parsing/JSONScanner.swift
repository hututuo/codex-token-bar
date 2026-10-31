import Foundation

struct JSONScanError: Error, Equatable {}

/// A number value with the facts Python-style checks need (`math.isfinite`, `> 0`, `>= 0`, `int()`).
struct JSONNumber: Equatable, Sendable {
    /// Truncated toward zero, saturated to `Int64`.
    var truncated: Int64
    /// False for a literal beyond the `Double` range.
    var isFinite: Bool
    var isPositive: Bool
    var isNonNegative: Bool
}

/// A member key inside the scanned buffer.
struct JSONKey {
    let start: Int
    let count: Int
    let isEscaped: Bool
}

/// Validating, allocation-free JSON scanner over a borrowed byte buffer.
///
/// It walks one JSON document, lets callers pick the members they care about and skips (while fully validating)
/// everything else. It never recurses, so hostile nesting cannot exhaust the stack.
struct JSONScanner {
    static let maxDepth = 64
    static let maxCapturedStringBytes = 4096

    private let base: UnsafePointer<UInt8>
    private let end: Int
    private var position = 0
    private var depth = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        if let address = buffer.baseAddress, buffer.count > 0 {
            base = address.assumingMemoryBound(to: UInt8.self)
            end = buffer.count
        } else {
            base = UnsafePointer(bitPattern: 1)!
            end = 0
        }
    }

    // MARK: - Structure

    /// True when the buffer holds nothing but JSON whitespace.
    var isBlank: Bool {
        var index = 0
        while index < end {
            if !Self.isWhitespace(base[index]) { return false }
            index += 1
        }
        return true
    }

    mutating func beginObject() throws(JSONScanError) {
        skipWhitespace()
        guard position < end, base[position] == UInt8(ascii: "{") else { throw JSONScanError() }
        try enterContainer()
        position += 1
        expectFirstMember = true
    }

    private var expectFirstMember = false
    private var expectFirstElement = false

    /// Returns the next key of the current object (positioned at its value), or nil after the closing brace.
    mutating func nextMember() throws(JSONScanError) -> JSONKey? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        if base[position] == UInt8(ascii: "}") {
            position += 1
            depth -= 1
            expectFirstMember = false
            return nil
        }
        if expectFirstMember {
            expectFirstMember = false
        } else {
            guard base[position] == UInt8(ascii: ",") else { throw JSONScanError() }
            position += 1
            skipWhitespace()
        }
        guard position < end, base[position] == UInt8(ascii: "\"") else { throw JSONScanError() }
        let keyStart = position + 1
        let escaped = try skipString()
        let key = JSONKey(start: keyStart, count: position - 1 - keyStart, isEscaped: escaped)
        skipWhitespace()
        guard position < end, base[position] == UInt8(ascii: ":") else { throw JSONScanError() }
        position += 1
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        return key
    }

    /// Enters an array if the next value is one. Returns false (consuming nothing) otherwise.
    mutating func beginArrayIfPresent() throws(JSONScanError) -> Bool {
        skipWhitespace()
        guard position < end, base[position] == UInt8(ascii: "[") else { return false }
        try enterContainer()
        position += 1
        expectFirstElement = true
        return true
    }

    /// Advances to the next array element. Returns false after the closing bracket.
    mutating func nextElement() throws(JSONScanError) -> Bool {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        if base[position] == UInt8(ascii: "]") {
            position += 1
            depth -= 1
            expectFirstElement = false
            return false
        }
        if expectFirstElement {
            expectFirstElement = false
        } else {
            guard base[position] == UInt8(ascii: ",") else { throw JSONScanError() }
            position += 1
            skipWhitespace()
        }
        guard position < end else { throw JSONScanError() }
        return true
    }

    /// Requires that only whitespace follows the document.
    mutating func finish() throws(JSONScanError) {
        skipWhitespace()
        guard position == end, depth == 0 else { throw JSONScanError() }
    }

    // MARK: - Peeking

    var nextIsObject: Bool { peekByte() == UInt8(ascii: "{") }
    var nextIsString: Bool { peekByte() == UInt8(ascii: "\"") }

    // MARK: - Keys

    func key(_ key: JSONKey, is name: StaticString) -> Bool {
        if !key.isEscaped {
            guard key.count == name.utf8CodeUnitCount else { return false }
            return memcmp(base + key.start, name.utf8Start, key.count) == 0
        }
        guard let decoded = decodeString(start: key.start, count: key.count) else { return false }
        return decoded.elementsEqual(UnsafeBufferPointer(start: name.utf8Start, count: name.utf8CodeUnitCount))
    }

    /// The text of a member key.
    func string(of key: JSONKey) -> String? {
        guard key.count <= Self.maxCapturedStringBytes else { return nil }
        if !key.isEscaped {
            return String(decoding: UnsafeBufferPointer(start: base + key.start, count: key.count), as: UTF8.self)
        }
        return decodeString(start: key.start, count: key.count).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Values

    /// Reads a string value of at most `maxCapturedStringBytes`. Other values (and longer strings) are skipped.
    mutating func readString() throws(JSONScanError) -> String? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        guard count <= Self.maxCapturedStringBytes else { return nil }
        if !escaped {
            return String(decoding: UnsafeBufferPointer(start: base + start, count: count), as: UTF8.self)
        }
        guard let bytes = decodeString(start: start, count: count) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a string value: nil when the value is not a string, `.some(nil)` for a string longer than
    /// `maxCapturedStringBytes`.
    mutating func readStringValue() throws(JSONScanError) -> String?? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        guard count <= Self.maxCapturedStringBytes else { return .some(nil) }
        if !escaped {
            return String(decoding: UnsafeBufferPointer(start: base + start, count: count), as: UTF8.self)
        }
        return .some(decodeString(start: start, count: count).map { String(decoding: $0, as: UTF8.self) })
    }

    /// Like `readString()`, but an empty string counts as missing.
    mutating func readNonEmptyString() throws(JSONScanError) -> String? {
        guard let value = try readString(), !value.isEmpty else { return nil }
        return value
    }

    /// Matches a string value against candidates without allocating. Returns the index, -1 for any other string,
    /// or nil when the value is not a string.
    mutating func readStringMatch(_ candidates: [StaticString]) throws(JSONScanError) -> Int? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        if escaped {
            guard count <= Self.maxCapturedStringBytes, let bytes = decodeString(start: start, count: count) else {
                return -1
            }
            for (index, candidate) in candidates.enumerated()
            where bytes.elementsEqual(UnsafeBufferPointer(start: candidate.utf8Start, count: candidate.utf8CodeUnitCount)) {
                return index
            }
            return -1
        }
        for (index, candidate) in candidates.enumerated()
        where candidate.utf8CodeUnitCount == count && memcmp(base + start, candidate.utf8Start, count) == 0 {
            return index
        }
        return -1
    }

    /// Whether a string value is non-empty, without materializing it. Returns nil when the value is not a string.
    mutating func readStringIsNonEmpty() throws(JSONScanError) -> Bool? {
        guard let (_, count, _) = try readStringSpan() else { return nil }
        return count > 0
    }

    /// Whether a string value has a character that is not whitespace (Python `str.strip()` semantics), without
    /// materializing it. Returns nil when the value is not a string.
    mutating func readStringHasVisibleText() throws(JSONScanError) -> Bool? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        var index = start
        let stop = start + count
        while index < stop {
            let byte = base[index]
            let scalar: UInt32
            if byte == UInt8(ascii: "\\"), escaped {
                let escape = base[index + 1]
                index += 2
                switch escape {
                case UInt8(ascii: "b"): scalar = 0x08
                case UInt8(ascii: "f"): scalar = 0x0C
                case UInt8(ascii: "n"): scalar = 0x0A
                case UInt8(ascii: "r"): scalar = 0x0D
                case UInt8(ascii: "t"): scalar = 0x09
                case UInt8(ascii: "u"):
                    guard let unit = hex4(at: index, limit: stop) else { return true }
                    index += 4
                    scalar = UInt32(unit)
                default: scalar = UInt32(escape)
                }
            } else if byte < 0x80 {
                scalar = UInt32(byte)
                index += 1
            } else {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                var value = UInt32(byte) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
                for offset in 1..<length where index + offset < stop {
                    value = value << 6 | (UInt32(base[index + offset]) & 0x3F)
                }
                scalar = value
                index += length
            }
            if !Self.isPythonWhitespace(scalar) { return true }
        }
        return false
    }

    /// `str.isspace()` of Python: Unicode White_Space plus the separators U+001C–U+001F. Surrogates count as text.
    static func isPythonWhitespace(_ value: UInt32) -> Bool {
        if (0x09...0x0D).contains(value) || (0x1C...0x20).contains(value) { return true }
        guard value >= 0x80, let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isWhitespace
    }

    /// Checks whether a string value starts with `prefix` without materializing it.
    /// Returns nil when the value is not a string.
    mutating func readStringHasPrefix(_ prefix: StaticString) throws(JSONScanError) -> Bool? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        let prefixCount = prefix.utf8CodeUnitCount
        if !escaped {
            return count >= prefixCount && memcmp(base + start, prefix.utf8Start, prefixCount) == 0
        }
        let window = min(count, prefixCount * 6 + 12)
        guard let decoded = decodePrefix(start: start, count: count, limit: window) else { return false }
        guard decoded.count >= prefixCount else { return false }
        return decoded.prefix(prefixCount).elementsEqual(UnsafeBufferPointer(start: prefix.utf8Start, count: prefixCount))
    }

    /// Reads a timestamp string (RFC 3339) as Unix milliseconds. Returns nil for any other value.
    mutating func readTimestamp() throws(JSONScanError) -> Int64? {
        guard let (start, count, escaped) = try readStringSpan() else { return nil }
        if !escaped {
            return Timestamp.parse(UnsafeBufferPointer(start: base + start, count: count))
        }
        // A timestamp has at most 64 characters, each at most a 6-byte `\uXXXX` escape (METRICS 3.1).
        guard count <= 384, let bytes = decodeString(start: start, count: count) else { return nil }
        return bytes.withUnsafeBufferPointer { Timestamp.parse($0) }
    }

    /// Reads a number as a saturated Int64 (fractions truncate toward zero). Non-numbers are skipped and give nil.
    mutating func readInteger() throws(JSONScanError) -> Int64? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        let first = base[position]
        guard first == UInt8(ascii: "-") || Self.isDigit(first) else {
            try skipValue()
            return nil
        }
        let start = position
        let isInteger = try skipNumber()
        return Self.integerValue(base: base, start: start, end: position, isInteger: isInteger)
    }

    /// Reads an integer literal from 0 through `Int64.max` (a Codex ordinal, METRICS 3.5). Anything else gives nil.
    mutating func readOrdinal() throws(JSONScanError) -> Int64? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        let first = base[position]
        guard first == UInt8(ascii: "-") || Self.isDigit(first) else {
            try skipValue()
            return nil
        }
        let start = position
        guard try skipNumber() else { return nil }
        var index = first == UInt8(ascii: "-") ? start + 1 : start
        var value: Int64 = 0
        while index < position {
            let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = multiplied.addingReportingOverflow(Int64(base[index] - UInt8(ascii: "0")))
            if overflow1 || overflow2 { return nil }
            value = added
            index += 1
        }
        return first == UInt8(ascii: "-") && value != 0 ? nil : value
    }

    /// Reads a number the way Python's `json` does: integer literals are exact (saturated here), every other literal
    /// is the nearest `Double`, so it can be `-0.0` or infinite. Non-numbers are skipped and give nil.
    mutating func readNumber() throws(JSONScanError) -> JSONNumber? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        let first = base[position]
        guard first == UInt8(ascii: "-") || Self.isDigit(first) else {
            try skipValue()
            return nil
        }
        let start = position
        if try skipNumber() {
            let value = Self.integerValue(base: base, start: start, end: position, isInteger: true)
            // An integer literal beyond the double range is not finite (METRICS 3.6); only 309+ characters can be.
            let isFinite = position - start <= 308
                || Double(String(decoding: UnsafeBufferPointer(start: base + start, count: position - start), as: UTF8.self))?
                    .isFinite == true
            return JSONNumber(truncated: value, isFinite: isFinite, isPositive: value > 0, isNonNegative: value >= 0)
        }
        let text = String(decoding: UnsafeBufferPointer(start: base + start, count: position - start), as: UTF8.self)
        guard let value = Double(text) else { return nil }
        let truncated: Int64 = if value >= 0x1p63 {
            .max
        } else if value < -0x1p63 {
            .min
        } else {
            Int64(value.rounded(.towardZero))
        }
        return JSONNumber(truncated: truncated, isFinite: value.isFinite, isPositive: value > 0, isNonNegative: value >= 0)
    }

    /// Reads `true`/`false`. Other values are skipped and give nil.
    mutating func readBool() throws(JSONScanError) -> Bool? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        switch base[position] {
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return true
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return false
        default:
            try skipValue()
            return nil
        }
    }

    /// Consumes `null` and returns true, or returns false without consuming anything.
    mutating func readNull() throws(JSONScanError) -> Bool {
        skipWhitespace()
        guard position < end, base[position] == UInt8(ascii: "n") else { return false }
        try expectLiteral("null")
        return true
    }

    /// Skips and validates any value.
    mutating func skipValue() throws(JSONScanError) {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        switch base[position] {
        case UInt8(ascii: "\""):
            _ = try skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            try skipContainer()
        case UInt8(ascii: "t"):
            try expectLiteral("true")
        case UInt8(ascii: "f"):
            try expectLiteral("false")
        case UInt8(ascii: "n"):
            try expectLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            _ = try skipNumber()
        default:
            throw JSONScanError()
        }
    }

    // MARK: - Internals

    private func peekByte() -> UInt8? {
        var index = position
        while index < end, Self.isWhitespace(base[index]) { index += 1 }
        return index < end ? base[index] : nil
    }

    private mutating func enterContainer() throws(JSONScanError) {
        depth += 1
        guard depth <= Self.maxDepth else { throw JSONScanError() }
    }

    private mutating func readStringSpan() throws(JSONScanError) -> (Int, Int, Bool)? {
        skipWhitespace()
        guard position < end else { throw JSONScanError() }
        guard base[position] == UInt8(ascii: "\"") else {
            try skipValue()
            return nil
        }
        let start = position + 1
        let escaped = try skipString()
        return (start, position - 1 - start, escaped)
    }

    @inline(__always)
    private mutating func skipWhitespace() {
        while position < end, Self.isWhitespace(base[position]) { position += 1 }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONScanError) {
        let count = literal.utf8CodeUnitCount
        guard end - position >= count, memcmp(base + position, literal.utf8Start, count) == 0 else {
            throw JSONScanError()
        }
        position += count
    }

    /// Skips a string starting at the opening quote. Returns whether it contains escapes.
    private mutating func skipString() throws(JSONScanError) -> Bool {
        var index = position + 1
        var escaped = false
        let raw = UnsafeRawPointer(base)
        while true {
            while index + 8 <= end {
                let word = raw.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                if Self.hasSpecialByte(word) { break }
                index += 8
            }
            guard index < end else { throw JSONScanError() }
            let byte = base[index]
            if byte == UInt8(ascii: "\"") {
                position = index + 1
                return escaped
            }
            if byte == UInt8(ascii: "\\") {
                escaped = true
                index += 1
                guard index < end else { throw JSONScanError() }
                switch base[index] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    guard index + 4 < end,
                          Self.hexValue(base[index + 1]) != nil, Self.hexValue(base[index + 2]) != nil,
                          Self.hexValue(base[index + 3]) != nil, Self.hexValue(base[index + 4]) != nil
                    else { throw JSONScanError() }
                    index += 5
                default:
                    throw JSONScanError()
                }
            } else if byte < 0x20 {
                throw JSONScanError()
            } else if byte >= 0x80 {
                index = try validateUTF8Sequence(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Validates one multi-byte UTF-8 sequence (RFC 3629) and returns the index after it.
    private func validateUTF8Sequence(at index: Int) throws(JSONScanError) -> Int {
        let lead = base[index]
        let length: Int
        var lower: UInt8 = 0x80
        var upper: UInt8 = 0xBF
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; lower = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; upper = 0x9F
        case 0xF0: length = 4; lower = 0x90
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; upper = 0x8F
        default: throw JSONScanError()
        }
        guard index + length <= end else { throw JSONScanError() }
        let second = base[index + 1]
        guard second >= lower, second <= upper else { throw JSONScanError() }
        var offset = 2
        while offset < length {
            let next = base[index + offset]
            guard next >= 0x80, next <= 0xBF else { throw JSONScanError() }
            offset += 1
        }
        return index + length
    }

    /// Skips a number and returns whether it is an integer literal.
    private mutating func skipNumber() throws(JSONScanError) -> Bool {
        var index = position
        var isInteger = true
        if base[index] == UInt8(ascii: "-") { index += 1 }
        guard index < end else { throw JSONScanError() }
        if base[index] == UInt8(ascii: "0") {
            index += 1
        } else if Self.isDigit(base[index]) {
            while index < end, Self.isDigit(base[index]) { index += 1 }
        } else {
            throw JSONScanError()
        }
        if index < end, base[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard index < end, Self.isDigit(base[index]) else { throw JSONScanError() }
            while index < end, Self.isDigit(base[index]) { index += 1 }
        }
        if index < end, base[index] == UInt8(ascii: "e") || base[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < end, base[index] == UInt8(ascii: "+") || base[index] == UInt8(ascii: "-") { index += 1 }
            guard index < end, Self.isDigit(base[index]) else { throw JSONScanError() }
            while index < end, Self.isDigit(base[index]) { index += 1 }
        }
        position = index
        return isInteger
    }

    /// Skips an object or array iteratively, validating its contents.
    private mutating func skipContainer() throws(JSONScanError) {
        // Bit i of `kinds` is set when nesting level i is an object.
        var kinds: UInt64 = 0
        var level = 0

        func isObject(_ level: Int, _ kinds: UInt64) -> Bool { (kinds >> UInt64(level - 1)) & 1 == 1 }

        // Opens the container at `position`. Returns true when it is immediately closed.
        func open(_ scanner: inout JSONScanner) throws(JSONScanError) -> Bool {
            let isObj = scanner.base[scanner.position] == UInt8(ascii: "{")
            level += 1
            guard scanner.depth + level <= Self.maxDepth else { throw JSONScanError() }
            if isObj { kinds |= (1 << UInt64(level - 1)) } else { kinds &= ~(1 << UInt64(level - 1)) }
            scanner.position += 1
            scanner.skipWhitespace()
            guard scanner.position < scanner.end else { throw JSONScanError() }
            let closer = isObj ? UInt8(ascii: "}") : UInt8(ascii: "]")
            if scanner.base[scanner.position] == closer {
                scanner.position += 1
                level -= 1
                return true
            }
            return false
        }

        var needsValue = !(try open(&self))
        while level > 0 {
            if needsValue {
                if isObject(level, kinds) {
                    guard position < end, base[position] == UInt8(ascii: "\"") else { throw JSONScanError() }
                    _ = try skipString()
                    skipWhitespace()
                    guard position < end, base[position] == UInt8(ascii: ":") else { throw JSONScanError() }
                    position += 1
                    skipWhitespace()
                }
                guard position < end else { throw JSONScanError() }
                let byte = base[position]
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    if !(try open(&self)) { continue }
                } else {
                    try skipScalar()
                }
                needsValue = false
            }
            skipWhitespace()
            guard position < end else { throw JSONScanError() }
            let byte = base[position]
            if byte == UInt8(ascii: ",") {
                position += 1
                skipWhitespace()
                needsValue = true
                continue
            }
            let closer = isObject(level, kinds) ? UInt8(ascii: "}") : UInt8(ascii: "]")
            guard byte == closer else { throw JSONScanError() }
            position += 1
            level -= 1
        }
    }

    private mutating func skipScalar() throws(JSONScanError) {
        switch base[position] {
        case UInt8(ascii: "\""):
            _ = try skipString()
        case UInt8(ascii: "t"):
            try expectLiteral("true")
        case UInt8(ascii: "f"):
            try expectLiteral("false")
        case UInt8(ascii: "n"):
            try expectLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            _ = try skipNumber()
        default:
            throw JSONScanError()
        }
    }

    // MARK: - Decoding

    private func decodeString(start: Int, count: Int) -> [UInt8]? {
        decodePrefix(start: start, count: count, limit: count)
    }

    /// Decodes escapes in the first `limit` raw bytes of a validated string body.
    private func decodePrefix(start: Int, count: Int, limit: Int) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, 256))
        var index = start
        let stop = start + min(count, limit)
        while index < stop {
            let byte = base[index]
            guard byte == UInt8(ascii: "\\") else {
                output.append(byte)
                index += 1
                continue
            }
            guard index + 1 < start + count else { return nil }
            let escape = base[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "u"):
                guard let unit = hex4(at: index, limit: start + count) else { return nil }
                index += 4
                var scalarValue = UInt32(unit)
                if (0xD800...0xDBFF).contains(unit),
                   index + 6 <= start + count,
                   base[index] == UInt8(ascii: "\\"), base[index + 1] == UInt8(ascii: "u"),
                   let low = hex4(at: index + 2, limit: start + count), (0xDC00...0xDFFF).contains(low) {
                    scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    index += 6
                }
                let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                output.append(contentsOf: UTF8.encode(scalar)!)
            default:
                output.append(escape)
            }
        }
        return output
    }

    private func hex4(at index: Int, limit: Int) -> UInt16? {
        guard index + 4 <= limit else { return nil }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = Self.hexValue(base[index + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    // MARK: - Byte classes

    @inline(__always)
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    @inline(__always)
    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// True when any byte is a quote, a backslash, a control character or non-ASCII.
    @inline(__always)
    private static func hasSpecialByte(_ word: UInt64) -> Bool {
        let ones: UInt64 = 0x0101_0101_0101_0101
        let high: UInt64 = 0x8080_8080_8080_8080
        let quote = word ^ (ones &* 0x22)
        let backslash = word ^ (ones &* 0x5C)
        let hasQuote = (quote &- ones) & ~quote
        let hasBackslash = (backslash &- ones) & ~backslash
        let hasControl = (word &- ones &* 0x20) & ~word
        return ((hasQuote | hasBackslash | hasControl) & high) | (word & high) != 0
    }

    private static func integerValue(base: UnsafePointer<UInt8>, start: Int, end: Int, isInteger: Bool) -> Int64 {
        if isInteger {
            var index = start
            let negative = base[index] == UInt8(ascii: "-")
            if negative { index += 1 }
            var value: Int64 = 0
            while index < end {
                let digit = Int64(base[index] - UInt8(ascii: "0"))
                let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
                let (added, overflow2) = multiplied.addingReportingOverflow(digit)
                if overflow1 || overflow2 { return negative ? Int64.min : Int64.max }
                value = added
                index += 1
            }
            return negative ? -value : value
        }
        guard end - start <= 512 else { return base[start] == UInt8(ascii: "-") ? Int64.min : Int64.max }
        let text = String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
        guard let double = Double(text), double.isFinite else {
            return base[start] == UInt8(ascii: "-") ? Int64.min : Int64.max
        }
        if double >= 9.2e18 { return Int64.max }
        if double <= -9.2e18 { return Int64.min }
        return Int64(double.rounded(.towardZero))
    }
}
