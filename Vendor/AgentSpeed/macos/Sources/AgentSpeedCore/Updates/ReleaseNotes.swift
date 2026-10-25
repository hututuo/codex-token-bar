import Foundation

/// A block of release notes. Inline Markdown (emphasis, code, links) stays in the text for the UI to render.
public enum ReleaseNotesBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, depth: Int, text: String)
    case code(String)
    case quote(String)
    case rule
}

/// Splits GitHub release notes into blocks. Covers what release notes use (ATX and setext headings, lists, fenced
/// code, quotes, rules); single newlines inside a paragraph are kept as line breaks, as GitHub shows them.
public enum ReleaseNotes {
    public static let maxCharacters = 20_000
    private static let maxDepth = 3

    public static func blocks(from markdown: String) -> [ReleaseNotesBlock] {
        var parser = Parser()
        for line in lines(of: markdown) { parser.consume(line) }
        return parser.finish()
    }

    private static func lines(of markdown: String) -> [String] {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = removingComments(text)
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
            if let lastBreak = text.lastIndex(of: "\n") { text = String(text[..<lastBreak]) }
            text += "\n…"
        }
        return text.components(separatedBy: "\n")
    }

    private static func removingComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "-->") else { return result }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private struct Parser {
        private var blocks: [ReleaseNotesBlock] = []
        private var paragraph: [String] = []
        private var item: (marker: String, depth: Int, text: String)?
        private var fence: (marker: String, lines: [String])?
        private var quote: [String] = []

        mutating func consume(_ raw: String) {
            if var open = fence {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix(open.marker) {
                    blocks.append(.code(open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(raw)
                    fence = open
                }
                return
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                return
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = (String(line.prefix(3)), [])
                return
            }
            if let level = setextLevel(line), paragraph.count == 1, item == nil {
                blocks.append(.heading(level: level, text: paragraph[0]))
                paragraph = []
                return
            }
            if isRule(line) {
                flush()
                blocks.append(.rule)
                return
            }
            if let heading = heading(line) {
                flush()
                blocks.append(heading)
                return
            }
            if line.hasPrefix(">") {
                flushParagraph()
                flushItem()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                return
            }
            if let listItem = listItem(raw) {
                flush()
                item = listItem
                return
            }
            if var open = item {
                open.text += " " + line
                item = open
                return
            }
            flushQuote()
            paragraph.append(line)
        }

        mutating func finish() -> [ReleaseNotesBlock] {
            if let open = fence {
                blocks.append(.code(open.lines.joined(separator: "\n")))
                fence = nil
            }
            flush()
            return blocks
        }

        private mutating func flush() {
            flushParagraph()
            flushItem()
            flushQuote()
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        private mutating func flushItem() {
            guard let open = item else { return }
            blocks.append(.listItem(marker: open.marker, depth: open.depth, text: open.text))
            item = nil
        }

        private mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }

        private func heading(_ line: String) -> ReleaseNotesBlock? {
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = line.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // A closing sequence only counts after whitespace, so "# C#" keeps its "#".
            let closing = text.dropLast(text.reversed().prefix { $0 == "#" }.count)
            if closing.isEmpty || closing.last == " " || closing.last == "\t" { text = String(closing) }
            text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .heading(level: hashes, text: text)
        }

        private func setextLevel(_ line: String) -> Int? {
            if line.allSatisfy({ $0 == "=" }) { return 1 }
            if line.count >= 2, line.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        private func isRule(_ line: String) -> Bool {
            let marks = line.filter { $0 != " " }
            guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
            return marks.allSatisfy { $0 == first }
        }

        private func listItem(_ raw: String) -> (marker: String, depth: Int, text: String)? {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let body = raw.drop { $0 == " " || $0 == "\t" }
            let depth = min(indent / 2, ReleaseNotes.maxDepth)
            if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
                let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : ("•", depth, text)
            }
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            let after = body.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else {
                return nil
            }
            let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("\(digits).", depth, text)
        }
    }
}
