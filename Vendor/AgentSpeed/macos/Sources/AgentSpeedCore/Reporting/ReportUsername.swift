import Foundation

/// A service's `username` rules from its discovery document (REPORTING 3.2, 4.3), clamped to the protocol's ranges.
public struct ReportUsernameRules: Equatable, Hashable, Sendable, Codable {
    public enum Charset: String, Equatable, Hashable, Sendable, Codable {
        case unicode
        case ascii
    }

    public var minLength: Int
    public var maxLength: Int
    public var charset: Charset
    public var spaces: Bool

    public static let standard = ReportUsernameRules()

    public init(minLength: Int = 2, maxLength: Int = 32, charset: Charset = .unicode, spaces: Bool = true) {
        self.minLength = min(max(1, minLength), 12)
        self.maxLength = min(max(12, maxLength), 32)
        self.charset = charset
        self.spaces = spaces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minLength: try container.decodeIfPresent(Int.self, forKey: .minLength) ?? 2,
            maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength) ?? 32,
            charset: try container.decodeIfPresent(Charset.self, forKey: .charset) ?? .unicode,
            spaces: try container.decodeIfPresent(Bool.self, forKey: .spaces) ?? true
        )
    }
}

/// The reasons of REPORTING 4.3, in check order.
public enum ReportUsernameProblem: String, Equatable, Sendable {
    case characters
    case length
    case spaces
    case start
}

/// Username grammar, default names and comparison keys of REPORTING 4.3 and DESIGN 11, following
/// `spec/tools/report_reference.py` code point by code point.
public enum ReportUsername {
    static let maxMarksInARow = 4
    static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "\u{02BC}", "`"]
    static let randomPrefix = "racer-"
    static let randomAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    /// NFKC, which the client applies before validating and sending (REPORTING 4.3).
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// The first failing check of REPORTING 4.3, or nil when the name is valid for `rules`.
    public static func validate(_ name: String, rules: ReportUsernameRules) -> ReportUsernameProblem? {
        let scalars = Array(name.unicodeScalars)
        guard normalized(name).unicodeScalars.elementsEqual(scalars) else { return .characters }
        guard (rules.minLength...rules.maxLength).contains(scalars.count) else { return .length }
        var marks = 0
        for scalar in scalars {
            if isSpace(scalar) && scalar != " " { return .spaces }
            if !isAllowed(scalar, rules) { return scalar == " " ? .spaces : .characters }
            marks = isMark(scalar) ? marks + 1 : 0
            if marks > maxMarksInARow { return .characters }
        }
        if !isLetterOrNumber(scalars[0], rules) { return .start }
        if scalars.last == " " || zip(scalars, scalars.dropFirst()).contains(where: { $0 == " " && $1 == " " }) {
            return .spaces
        }
        return nil
    }

    /// The computer name fitted to `rules` (DESIGN 11 `fit`), or nil when nothing valid remains.
    public static func fit(computerName: String, rules: ReportUsernameRules) -> String? {
        var text = Array(normalized(computerName).unicodeScalars).filter { !apostrophes.contains($0) }
        if rules.charset == .ascii {
            text = string(text).decomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { ![.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory) }
        }
        let separator: Unicode.Scalar = rules.spaces ? " " : "-"
        text = text.map { !isSpace($0) && isAllowed($0, rules) ? $0 : separator }
        text = collapsedSeparators(text)
        if let start = text.firstIndex(where: { isLetterOrNumber($0, rules) }) {
            text.removeSubrange(..<start)
        } else {
            text = []
        }
        text = Array(text.prefix(rules.maxLength))
        while let last = text.last, [" ", "-", "_", "."].contains(last) { text.removeLast() }
        let name = string(text)
        return validate(name, rules: rules) == nil ? name : nil
    }

    /// `racer-` and 6 characters from the system's cryptographic random generator (DESIGN 11).
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        randomPrefix + String((0..<6).map { _ in randomAlphabet[Int.random(in: 0..<randomAlphabet.count, using: &generator)] })
    }

    /// `NFKC(casefold(NFKC(name)))` with full Unicode case folding (REPORTING 4.3).
    public static func comparisonKey(_ name: String) -> String {
        normalized(caseFolded(normalized(name)))
    }

    /// Whether two usernames are the same name for uniqueness (REPORTING 4.3).
    public static func isSameName(_ a: String, _ b: String) -> Bool {
        comparisonKey(a).unicodeScalars.elementsEqual(comparisonKey(b).unicodeScalars)
    }

    // MARK: - Python character classes

    /// `str.isspace()`: the ASCII separators and Unicode White_Space.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0x09...0x0D).contains(value) || (0x1C...0x20).contains(value) { return true }
        return value >= 0x80 && scalar.properties.isWhitespace
    }

    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        default: false
        }
    }

    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    static func isLetterOrNumberCategory(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    /// `_letter_or_number`.
    static func isLetterOrNumber(_ scalar: Unicode.Scalar, _ rules: ReportUsernameRules) -> Bool {
        rules.charset == .ascii ? isASCIIAlphanumeric(scalar) : isLetterOrNumberCategory(scalar)
    }

    /// `_allowed`.
    static func isAllowed(_ scalar: Unicode.Scalar, _ rules: ReportUsernameRules) -> Bool {
        if scalar == " " { return rules.spaces }
        if scalar == "_" || scalar == "-" || scalar == "." { return true }
        if rules.charset == .ascii { return isASCIIAlphanumeric(scalar) }
        return isLetterOrNumberCategory(scalar) || isMark(scalar)
    }

    /// `[ \-]*-[ \-]*` → `-`, then ` {2,}` → ` `: a run of spaces and hyphens becomes one `-` when it contains one,
    /// else one space.
    static func collapsedSeparators(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var index = 0
        while index < text.count {
            guard text[index] == " " || text[index] == "-" else {
                out.append(text[index])
                index += 1
                continue
            }
            var end = index
            var hasHyphen = false
            while end < text.count, text[end] == " " || text[end] == "-" {
                hasHyphen = hasHyphen || text[end] == "-"
                end += 1
            }
            out.append(hasHyphen ? "-" : " ")
            index = end
        }
        return out
    }

    /// `str.casefold()`: Foundation's full case folding, with the code points where it departs from Unicode
    /// `CaseFolding.txt` (Cherokee folds to upper case, U+1C80–U+1C88 to the common Cyrillic letters) mapped as
    /// Python maps them.
    static func caseFolded(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let folded = foldingException(scalar) {
                out.append(folded)
            } else if scalar.isASCII {
                out.append(("A"..."Z").contains(scalar) ? Unicode.Scalar(UInt8(scalar.value + 0x20)) : scalar)
            } else {
                out.append(contentsOf: String(scalar).folding(options: .caseInsensitive, locale: nil).unicodeScalars)
            }
        }
        return String(out)
    }

    private static let cyrillicExceptions: [UInt32: UInt32] = [
        0x1C80: 0x0432, 0x1C81: 0x0434, 0x1C82: 0x043E, 0x1C83: 0x0441, 0x1C84: 0x0442,
        0x1C85: 0x0442, 0x1C86: 0x044A, 0x1C87: 0x0463, 0x1C88: 0xA64B,
    ]

    private static func foldingException(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        switch value {
        case 0x13A0...0x13F5: return scalar
        case 0x13F8...0x13FD: return Unicode.Scalar(value - 8)
        case 0xAB70...0xABBF: return Unicode.Scalar(value - 0xAB70 + 0x13A0)
        default: return cyrillicExceptions[value].flatMap { Unicode.Scalar($0) }
        }
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
