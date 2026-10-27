import Foundation

/// A number as written in a JSON document. The literal is kept so prices and rates convert to exact decimals
/// (METRICS 9.1, NETWORK 4), and so integers stay distinguishable from fractions the way Python's `json` tells
/// `int` from `float`.
public struct JSONLiteral: Equatable, Hashable, Sendable {
    public let text: String
    /// No fraction and no exponent: Python reads it as an `int`.
    public let isInteger: Bool

    public init(_ text: String) {
        self.text = text
        isInteger = !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" })
    }

    /// The value as `spec/tools/prices.py` sees it: an integer literal exactly, any other literal as the decimal
    /// of its nearest `Double` written in the shortest form that reads back (Python's `Decimal(repr(float))`), so
    /// `0.20000000000000001` is `0.2`. Nil when it is not finite or beyond `Decimal`'s range.
    public var decimal: Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        if isInteger {
            guard let value = Decimal(string: text, locale: posix), !value.isNaN else { return nil }
            return value
        }
        guard let double = Double(text), double.isFinite,
              let value = Decimal(string: "\(double)", locale: posix), !value.isNaN else { return nil }
        return value
    }

    /// The value of an integer literal that fits in 64 bits.
    public var int64: Int64? {
        isInteger ? Int64(text) : nil
    }

    /// The nearest `Double` (`float()` of the literal).
    public var double: Double? { Double(text) }
}

/// A parsed JSON document. Objects keep the last value of a repeated key, as Python's `json` does.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(JSONLiteral)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var literal: JSONLiteral? {
        if case .number(let literal) = self { return literal }
        return nil
    }

    /// An integer literal (never a boolean or a fraction).
    public var int64: Int64? { literal?.int64 }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }
}

public enum JSONParseError: Error, Equatable, Sendable {
    case invalid(offset: Int)
    case tooDeep
}

/// Strict RFC 8259 parser: UTF-8 without a byte-order mark, no `NaN` or `Infinity`, no control characters inside
/// strings. Nesting is limited so a hostile document cannot exhaust the stack.
public enum JSONParser {
    public static let defaultMaxDepth = 64

    public static func parse(_ data: Data, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) -> JSONValue {
        let bytes = [UInt8](data)
        var parser = Cursor(bytes: bytes, maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw .invalid(offset: parser.index) }
        return value
    }

    public static func parse(_ text: String, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) -> JSONValue {
        try parse(Data(text.utf8), maxDepth: maxDepth)
    }

    private struct Cursor {
        let bytes: [UInt8]
        let maxDepth: Int
        var index = 0

        init(bytes: [UInt8], maxDepth: Int) {
            self.bytes = bytes
            self.maxDepth = maxDepth
        }

        private var failure: JSONParseError { .invalid(offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws(JSONParseError) -> JSONValue {
            guard index < bytes.count else { throw failure }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth + 1)
            case UInt8(ascii: "["): return try array(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default:
                return .number(try number())
            }
        }

        private mutating func object(depth: Int) throws(JSONParseError) -> JSONValue {
            guard depth <= maxDepth else { throw .tooDeep }
            index += 1
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure }
                index += 1
                skipWhitespace()
                members[key] = try value(depth: depth)
                skipWhitespace()
                guard index < bytes.count else { throw failure }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw failure
                }
            }
        }

        private mutating func array(depth: Int) throws(JSONParseError) -> JSONValue {
            guard depth <= maxDepth else { throw .tooDeep }
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth))
                skipWhitespace()
                guard index < bytes.count else { throw failure }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    throw failure
                }
            }
        }

        private mutating func literal(_ word: StaticString) throws(JSONParseError) {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { throw failure }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { throw failure }
            index += count
        }

        private mutating func number() throws(JSONParseError) -> JSONLiteral {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw failure }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { throw failure }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { throw failure }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            return JSONLiteral(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func string() throws(JSONParseError) -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flush(_ cursor: Cursor, upTo end: Int, into scalars: inout String.UnicodeScalarView) {
                if end > runStart {
                    scalars.append(contentsOf: String(decoding: cursor.bytes[runStart..<end], as: UTF8.self).unicodeScalars)
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(self, upTo: index, into: &scalars)
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 { throw failure }
                if byte == UInt8(ascii: "\\") {
                    flush(self, upTo: index, into: &scalars)
                    index += 1
                    guard index < bytes.count else { throw failure }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        scalars.append(try unicodeEscape())
                    default:
                        throw failure
                    }
                    runStart = index
                    continue
                }
                if byte >= 0x80 {
                    index += try utf8Sequence(at: index)
                } else {
                    index += 1
                }
            }
            throw failure
        }

        /// `\uXXXX` (the `\u` already consumed), joining surrogate pairs; a lone surrogate becomes U+FFFD.
        private mutating func unicodeEscape() throws(JSONParseError) -> Unicode.Scalar {
            let high = try hex4()
            if (0xD800...0xDBFF).contains(high), index + 1 < bytes.count,
               bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try hex4()
                if (0xDC00...0xDFFF).contains(low) {
                    let value = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
                index = saved
            }
            return Unicode.Scalar(UInt32(high)) ?? "\u{FFFD}"
        }

        private mutating func hex4() throws(JSONParseError) -> UInt16 {
            guard index + 4 <= bytes.count else { throw failure }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw failure
                }
                value = value << 4 | UInt16(digit)
                index += 1
            }
            return value
        }

        /// Length of the valid UTF-8 sequence starting at `start`.
        private func utf8Sequence(at start: Int) throws(JSONParseError) -> Int {
            let lead = bytes[start]
            let length: Int
            let minimum: UInt32
            switch lead {
            case 0xC2...0xDF: (length, minimum) = (2, 0x80)
            case 0xE0...0xEF: (length, minimum) = (3, 0x800)
            case 0xF0...0xF4: (length, minimum) = (4, 0x10000)
            default: throw JSONParseError.invalid(offset: start)
            }
            guard start + length <= bytes.count else { throw JSONParseError.invalid(offset: start) }
            var value = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
            for offset in 1..<length {
                let byte = bytes[start + offset]
                guard byte & 0xC0 == 0x80 else { throw JSONParseError.invalid(offset: start) }
                value = value << 6 | UInt32(byte & 0x3F)
            }
            guard value >= minimum, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else {
                throw JSONParseError.invalid(offset: start)
            }
            return length
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }
}
