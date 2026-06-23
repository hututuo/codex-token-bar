import Foundation

struct CodexRadarFeedItem: Equatable, Identifiable, Sendable {
    var id: String { guid }

    let title: String
    let link: String
    let guid: String
    let pubDate: String
    let description: String
}

enum CodexRadarFeedParser {
    static func parse(_ data: Data) throws -> [CodexRadarFeedItem] {
        let delegate = CodexRadarFeedXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CodexRadarFeedParserError.invalidXML
        }
        return delegate.items
    }
}

enum CodexRadarFeedParserError: LocalizedError {
    case invalidXML

    var errorDescription: String? {
        "Codex Radar RSS 不是有效 XML"
    }
}

private final class CodexRadarFeedXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [CodexRadarFeedItem] = []
    private var isInsideItem = false
    private var currentElement = ""
    private var buffer = ""
    private var fields: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""
        if elementName == "item" {
            isInsideItem = true
            fields.removeAll(keepingCapacity: true)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isInsideItem else { return }

        if elementName == "item" {
            if let item = makeItem() {
                items.append(item)
            }
            isInsideItem = false
            fields.removeAll(keepingCapacity: true)
            buffer = ""
            currentElement = ""
            return
        }

        let normalized = buffer
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            fields[elementName] = normalized
        }
        buffer = ""
        currentElement = ""
    }

    private func makeItem() -> CodexRadarFeedItem? {
        guard let title = fields["title"],
              let link = fields["link"],
              let guid = fields["guid"],
              let pubDate = fields["pubDate"],
              let description = fields["description"] else {
            return nil
        }
        return CodexRadarFeedItem(
            title: title,
            link: link,
            guid: guid,
            pubDate: pubDate,
            description: description
        )
    }
}
