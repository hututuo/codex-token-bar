import Foundation

/// An ordered JSON document the client writes: report bodies, registrations and renames. Members keep their order,
/// integers are written without a fraction and rounded numbers with at most their decimals (REPORTING 6.7).
public indirect enum ReportJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// A value rounded half away from zero to `decimals` places, written without trailing zeros.
    case decimal(Double, decimals: Int)
    case string(String)
    case array([ReportJSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: ReportJSON

        public init(_ key: String, _ value: ReportJSON) {
            self.key = key
            self.value = value
        }
    }

    public static func object(_ pairs: KeyValuePairs<String, ReportJSON>) -> ReportJSON {
        .object(pairs.map { Member($0.key, $0.value) })
    }

    public static func int(_ value: Int) -> ReportJSON { .int(Int64(value)) }

    /// A non-negative integer, or `null` for nil (traffic rates before two samples).
    public static func optionalInt(_ value: Int64?) -> ReportJSON { value.map(ReportJSON.int) ?? .null }

    public subscript(key: String) -> ReportJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Compact UTF-8 without a byte order mark, as sent (REPORTING 2.3).
    public var compactData: Data {
        var out = ""
        write(into: &out, pretty: false, indent: 0)
        return Data(out.utf8)
    }

    /// Two-space indentation, `"key": value`, for the preview (DESIGN 11).
    public var prettyText: String {
        var out = ""
        write(into: &out, pretty: true, indent: 0)
        return out
    }

    /// The pretty text split into runs, so a view can color keys apart from values.
    public var prettyTokens: [ReportJSONToken] {
        var tokens: [ReportJSONToken] = []
        tokenize(into: &tokens, indent: 0)
        return tokens
    }

    // MARK: - Writing

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .decimal(let value, let decimals): out += Self.number(value, decimals: decimals)
        case .string(let text): out += Self.quoted(text)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + Self.spaces(indent + 1) }
                item.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + Self.spaces(indent) }
            out += "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + Self.spaces(indent + 1) }
                out += Self.quoted(member.key) + (pretty ? ": " : ":")
                member.value.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + Self.spaces(indent) }
            out += "}"
        }
    }

    private func tokenize(into tokens: inout [ReportJSONToken], indent: Int) {
        switch self {
        case .null, .bool, .int, .decimal:
            var text = ""
            write(into: &text, pretty: false, indent: 0)
            tokens.append(ReportJSONToken(text, .number))
        case .string(let text):
            tokens.append(ReportJSONToken(Self.quoted(text), .string))
        case .array(let items):
            guard !items.isEmpty else { tokens.append(ReportJSONToken("[]", .punctuation)); return }
            tokens.append(ReportJSONToken("[", .punctuation))
            for (index, item) in items.enumerated() {
                tokens.append(ReportJSONToken((index > 0 ? "," : "") + "\n" + Self.spaces(indent + 1), .punctuation))
                item.tokenize(into: &tokens, indent: indent + 1)
            }
            tokens.append(ReportJSONToken("\n" + Self.spaces(indent) + "]", .punctuation))
        case .object(let members):
            guard !members.isEmpty else { tokens.append(ReportJSONToken("{}", .punctuation)); return }
            tokens.append(ReportJSONToken("{", .punctuation))
            for (index, member) in members.enumerated() {
                tokens.append(ReportJSONToken((index > 0 ? "," : "") + "\n" + Self.spaces(indent + 1), .punctuation))
                tokens.append(ReportJSONToken(Self.quoted(member.key), .key))
                tokens.append(ReportJSONToken(": ", .punctuation))
                member.value.tokenize(into: &tokens, indent: indent + 1)
            }
            tokens.append(ReportJSONToken("\n" + Self.spaces(indent) + "}", .punctuation))
        }
    }

    private static func spaces(_ level: Int) -> String {
        String(repeating: "  ", count: level)
    }

    /// Half away from zero (REPORTING 6.7), at most `decimals` places, no trailing zeros, never `-0`.
    static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        if rounded == 0 { return "0" }
        var text = String(format: "%.\(decimals)f", rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// JSON string with only the required escapes; other characters stay UTF-8 (like `ensure_ascii=False`).
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// One run of the pretty-printed preview.
public struct ReportJSONToken: Equatable, Sendable {
    public enum Kind: Sendable { case key, string, number, punctuation }

    public var text: String
    public var kind: Kind

    public init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }
}
