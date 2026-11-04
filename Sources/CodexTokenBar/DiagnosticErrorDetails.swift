import Foundation

enum DiagnosticErrorDetails {
    // Error descriptions, reasons and paths can embed credentials even when userInfo
    // itself is never serialized. Sanitize recognizable credential syntax together
    // at the output boundary, before truncation can leave part of a secret behind.
    private static let redactions: [(NSRegularExpression, String)] = [
        (#"(?i)(\b[a-z][a-z0-9+.-]*://)[^/\s?#\"'<>]+@"#, "$1[redacted]@"),
        (#"(?im)(\b(?:proxy-authorization|authorization|set-cookie|cookie)[\"']?\s*[:=]\s*)[^\r\n]+"#, "$1[redacted]"),
        (#"(?i)(\bBearer\s+)[^\s\"'\\,;<>]+"#, "$1[redacted]"),
        (#"(?i)((?<![a-z0-9_])[\"']?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|password|passwd|secret|token)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s&,;\"'{}<>]+)"#, "$1[redacted]")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func text(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        for depth in 0..<6 {
            guard let cause = current, seen.insert(ObjectIdentifier(cause)).inserted else { break }
            lines.append("\(depth == 0 ? "错误" : "底层原因")：\(cause.domain) / \(cause.code) · \(cause.localizedDescription)")
            if let path = cause.userInfo[NSFilePathErrorKey] as? String { lines.append("文件：\(path)") }
            if let reason = cause.localizedFailureReason { lines.append("原因：\(reason)") }
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // No userInfo dump: it may contain network request credentials or response bodies.
        let sanitized = redactions.reduce(lines.joined(separator: "\n")) { value, rule in
            rule.0.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                            withTemplate: rule.1)
        }
        return String(sanitized.prefix(8192))
    }
}
