import Foundation

enum DiagnosticErrorDetails {
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
        return String(lines.joined(separator: "\n").prefix(8192))
    }
}
