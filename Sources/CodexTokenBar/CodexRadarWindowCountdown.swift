import Foundation

enum CodexRadarWindowCountdownParser {
    private static let pattern = #"<section\b[^>]*data-speed-window\s*=\s*["']open["'][^>]*>[\s\S]*?data-window-closes-at\s*=\s*["']([^"']+)["']"#

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
