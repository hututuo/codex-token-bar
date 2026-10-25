import Foundation

enum HarnessJSON {
    static func number(_ value: JSONValue?) -> JSONNumber? {
        guard let literal = value?.literal else { return nil }
        return Data(literal.text.utf8).withUnsafeBytes { bytes in
            var scanner = JSONScanner(bytes)
            return try? scanner.readNumber()
        }
    }

    static func count(_ value: JSONValue?) -> Int { TokenCount.clamp(number(value)?.truncated) }

    static func milliseconds(_ value: JSONValue?) -> Int64? {
        guard let number = number(value), number.isFinite else { return nil }
        return number.truncated
    }
}
