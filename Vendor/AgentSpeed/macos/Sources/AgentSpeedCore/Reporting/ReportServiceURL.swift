import Foundation

public enum ReportURLProblem: Error, Equatable, Sendable {
    case invalid
    case notHTTPS
}

/// A normalized service URL (REPORTING 2.1, 2.2).
public struct ReportServiceURL: Equatable, Hashable, Sendable, Codable {
    public static let maxLength = 2048
    static let loopbackHosts: Set<String> = ["127.0.0.1", "[::1]", "localhost"]
    static let discoveryPath = "/.well-known/agent-speed-report"

    /// `scheme://host[:port][path]`: lower-case host (IDNA A-labels), the port only when not the default, the path
    /// percent-encoded without a trailing `/`.
    public let string: String
    public let url: URL
    /// `https`, or `http` for a loopback test server.
    public let scheme: String
    /// The host alone (IPv6 in brackets), as shown to the user.
    public let host: String
    public let port: Int?
    public let path: String

    private init?(scheme: String, host: String, port: Int?, path: String) {
        let authority = port.map { "\(host):\($0)" } ?? host
        let string = "\(scheme)://\(authority)\(path)"
        guard string.unicodeScalars.count <= Self.maxLength, let url = URL(string: string),
              URL(string: string + Self.discoveryPath) != nil else { return nil }
        self.string = string
        self.url = url
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    /// `http` to `127.0.0.1`, `[::1]` or `localhost`: unencrypted local testing (REPORTING 2.2).
    public var isLoopbackHTTP: Bool { scheme == "http" }

    /// `host[:port]` as in REPORTING 5.3 line 3.
    public var authority: String { port.map { "\(host):\($0)" } ?? host }

    /// `scheme://authority`, the key of a stored service identity.
    public var origin: String { "\(scheme)://\(authority)" }

    /// REPORTING 2.1 step 3.
    public var discoveryURL: URL { URL(string: string + Self.discoveryPath)! }

    /// Endpoint URL `{api}{path}` where path starts with `/v1/` (REPORTING 2.4).
    public func appending(endpoint path: String) -> URL {
        precondition(path.hasPrefix("/v1/"), "endpoint paths start with /v1/")
        return URL(string: string + path)!
    }

    /// REPORTING 2.1: trims, prefixes `https://` when no scheme is given, then normalizes.
    public static func parse(_ input: String) -> Result<ReportServiceURL, ReportURLProblem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalid) }
        return normalize(hasScheme(trimmed) ? trimmed : "https://" + trimmed)
    }

    /// The discovery document's `api` (REPORTING 3.2): same rules; http only when the discovery itself was fetched
    /// over loopback http.
    public static func parseAPI(_ text: String, discoveryIsLoopbackHTTP: Bool) -> ReportServiceURL? {
        guard hasScheme(text), case .success(let api) = normalize(text) else { return nil }
        return api.isLoopbackHTTP && !discoveryIsLoopbackHTTP ? nil : api
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard case .success(let parsed) = Self.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid service URL"))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    public static func == (lhs: ReportServiceURL, rhs: ReportServiceURL) -> Bool {
        lhs.string == rhs.string
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(string)
    }

    // MARK: - Normalization

    static func hasScheme(_ text: String) -> Bool {
        guard let separator = text.range(of: "://") else { return false }
        let scheme = text[..<separator.lowerBound].unicodeScalars
        guard let first = scheme.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return scheme.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "+-.".unicodeScalars.contains(scalar))
        }
    }

    private static func normalize(_ text: String) -> Result<ReportServiceURL, ReportURLProblem> {
        guard ReportURLs.isCleanText(text), !text.contains("\\"), hasValidPercentEscapes(text),
              let components = URLComponents(string: text), let rawScheme = components.scheme else {
            return .failure(.invalid)
        }
        let scheme = rawScheme.lowercased()
        guard components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              let host = components.encodedHost.map({ $0.lowercased() }), isValidHost(host) else {
            return .failure(.invalid)
        }
        switch scheme {
        case "https": break
        case "http" where loopbackHosts.contains(host): break
        default: return .failure(.notHTTPS)
        }
        if let port = components.port, !(1...65535).contains(port) { return .failure(.invalid) }
        let port = components.port.flatMap { $0 == ReportURLs.defaultPort(scheme) ? nil : $0 }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard path.isEmpty || path.hasPrefix("/"), !hasDotSegment(path),
              let url = ReportServiceURL(scheme: scheme, host: host, port: port, path: path) else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    /// A DNS name of LDH labels (after IDNA), a dotted IPv4 address, or an IPv6 address in brackets.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.hasPrefix("[") {
            let inner = host.dropFirst().dropLast()
            return host.hasSuffix("]") && inner.contains(":")
                && inner.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit || $0 == ":" || $0 == "." }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    private static func hasValidPercentEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        Unicode.Scalar(byte).properties.isASCIIHexDigit
    }

    /// `.` and `..` segments (also percent-encoded) are refused so the signed path is the path sent (REPORTING 5.3).
    private static func hasDotSegment(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            let decoded = segment.replacingOccurrences(of: "%2e", with: ".", options: .caseInsensitive)
            return decoded == "." || decoded == ".."
        }
    }
}

public enum ReportURLs {
    /// REPORTING 5.3 line 3: lower-case host (IDNA A-labels; IPv6 in brackets), `:port` only when not the scheme
    /// default (443 https, 80 http).
    public static func authority(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "" }
        var host = (components.encodedHost ?? "").lowercased()
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        guard let port = components.port, port != defaultPort(components.scheme?.lowercased() ?? "") else { return host }
        return "\(host):\(port)"
    }

    /// REPORTING 5.3 line 4: path and query exactly as sent (percent-encoded form, no decoding), `/` when empty.
    public static func requestPath(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "/" }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return path }
        return "\(path)?\(query)"
    }

    /// A link of the schema's `$defs/httpsUrl` (REPORTING 2.2, 2.3): always `https`, no user information, at most
    /// 2048 code points, no white space, control or format characters.
    public static func httpsLink(_ text: String?) -> URL? {
        guard let text, text.unicodeScalars.count <= ReportServiceURL.maxLength, isCleanText(text),
              text.hasPrefix("https://") else { return nil }
        let rest = text.dropFirst(8)
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@"), authorityEnd == rest.endIndex || rest[authorityEnd] == "/" else {
            return nil
        }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    /// No white space (ECMAScript `\s`), control or format characters anywhere.
    static func isCleanText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: true
            default: scalar.properties.isWhitespace
            }
        }
    }
}
