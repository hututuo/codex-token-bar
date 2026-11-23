import Foundation

/// Local JSONL parses run synchronously on several worker threads. Keep the
/// formatters on their owning thread and keep the same two accepted formats.
enum LocalLogISO8601 {
    private final class Formatters {
        let fractional = ISO8601DateFormatter()
        lazy var ordinary = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
    }

    static func date(from text: String) -> Date? {
        let key = "TokenBar.LocalLogISO8601"
        let dictionary = Thread.current.threadDictionary
        let formatters: Formatters
        if let cached = dictionary[key] as? Formatters {
            formatters = cached
        } else {
            formatters = Formatters()
            dictionary[key] = formatters
        }
        return formatters.fractional.date(from: text) ?? formatters.ordinary.date(from: text)
    }
}
