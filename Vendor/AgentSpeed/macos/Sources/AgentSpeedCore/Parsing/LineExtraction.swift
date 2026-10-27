import Foundation

/// Result of decoding one transcript line into a compact record.
enum LineExtraction<Line: Sendable>: Sendable {
    case line(Line)
    /// Not a valid JSON object (METRICS 4).
    case malformed
    /// Empty or whitespace-only line; neither data nor malformed.
    case blank
}

extension LineExtraction: Equatable where Line: Equatable {}

extension JSONScanner {
    /// Skips the current value when it is not an object; otherwise enters it.
    mutating func beginObjectIfPresent() throws(JSONScanError) -> Bool {
        guard nextIsObject else {
            try skipValue()
            return false
        }
        try beginObject()
        return true
    }
}
