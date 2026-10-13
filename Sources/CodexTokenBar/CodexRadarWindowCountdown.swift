import Foundation

enum CodexRadarWindowCountdownParser {
    private static let pattern = #"<section\b[^>]*data-speed-window\s*=\s*["']open["'][^>]*>(?:(?!</?section\b)[\s\S])*?data-window-closes-at\s*=\s*["']([^"']+)["']"#

    static func isValidDeadline(_ value: String?) -> Bool {
        guard let value else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    static func deadline(in html: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let value = String(html[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
