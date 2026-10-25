import Foundation

/// The optional report sections, in the order of REPORTING 6.6.
public enum ReportSection: String, CaseIterable, Codable, Hashable, Sendable {
    case sources
    case models
    case cost
    case traffic
}

/// `apiKey.mode` (REPORTING 5.6).
public enum ReportAPIKeyMode: String, Codable, Equatable, Sendable {
    case none
    case optional
    case required
}

/// The discovery document's `limits` (REPORTING 3.2), clamped to the protocol's ranges.
public struct ReportLimits: Equatable, Hashable, Sendable, Codable {
    public var intervalSeconds: Int
    public var heartbeatSeconds: Int
    public var maxAgeSeconds: Int
    public var maxBodyBytes: Int
    public var maxModels: Int

    public static let standard = ReportLimits()
    /// The client never sends a larger body (REPORTING 3.2, 6.8).
    public static let clientMaxBodyBytes = 16_384

    public init(
        intervalSeconds: Int = 5, heartbeatSeconds: Int = 60, maxAgeSeconds: Int = 30, maxBodyBytes: Int = 16_384,
        maxModels: Int = 16
    ) {
        self.intervalSeconds = ReportClamp.value(intervalSeconds, 5...300)
        self.heartbeatSeconds = max(ReportClamp.value(heartbeatSeconds, 30...900), self.intervalSeconds)
        self.maxAgeSeconds = ReportClamp.value(maxAgeSeconds, 10...120)
        self.maxBodyBytes = ReportClamp.value(maxBodyBytes, 4096...65_536)
        self.maxModels = ReportClamp.value(maxModels, 0...16)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            intervalSeconds: try container.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 5,
            heartbeatSeconds: try container.decodeIfPresent(Int.self, forKey: .heartbeatSeconds) ?? 60,
            maxAgeSeconds: try container.decodeIfPresent(Int.self, forKey: .maxAgeSeconds) ?? 30,
            maxBodyBytes: try container.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? 16_384,
            maxModels: try container.decodeIfPresent(Int.self, forKey: .maxModels) ?? 16
        )
    }

    /// The largest body the client sends to this service.
    public var sendLimitBytes: Int { min(Self.clientMaxBodyBytes, maxBodyBytes) }
}

public enum ReportDiscoveryProblem: Error, Equatable, Sendable {
    case tooLarge
    case notJSON
    /// The first offending field, for logs only.
    case invalid(String)

    /// Not an `agent-speed-report` document at all (a web page, other JSON), as opposed to one that breaks a rule.
    public var isOtherDocument: Bool {
        switch self {
        case .tooLarge, .notJSON, .invalid("protocol"): true
        case .invalid: false
        }
    }
}

/// A validated discovery document (REPORTING 3.2). Text is plain and capped, optional links are kept only when
/// `https`, numbers are clamped.
public struct ReportDiscovery: Equatable, Sendable, Codable {
    public static let maxBytes = 65_536
    public static let supportedVersion = 1
    public static let protocolName = "agent-speed-report"

    public var versions: [Int]
    public var name: String
    /// `service.description`.
    public var summary: String?
    public var homepage: URL?
    public var terms: URL
    public var privacy: URL
    public var leaderboard: URL?
    public var contact: String?
    public var retentionDays: Int?
    public var api: ReportServiceURL
    public var apiKeyMode: ReportAPIKeyMode
    public var apiKeyURL: URL?
    public var usernameRules: ReportUsernameRules
    public var limits: ReportLimits
    public var sections: Set<ReportSection>
    public var extensions: ReportExtensions?

    /// False when the service shares no protocol version with this client ("needs a newer Agent Speed").
    public var supportsThisClient: Bool { versions.contains(Self.supportedVersion) }

    /// `data` is the body fetched from `service.discoveryURL`; `http` URLs are accepted only when that was loopback
    /// `http` (REPORTING 2.2).
    public static func parse(_ data: Data, service: ReportServiceURL) -> Result<ReportDiscovery, ReportDiscoveryProblem> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let document = try? JSONParser.parse(data), let root = document.object else { return .failure(.notJSON) }
        do {
            return .success(try ReportDiscovery(DocumentFields(root, path: ""), loopback: service.isLoopbackHTTP))
        } catch {
            return .failure(error)
        }
    }

    private init(_ root: DocumentFields, loopback: Bool) throws(ReportDiscoveryProblem) {
        guard try root.string("protocol") == Self.protocolName else { throw .invalid("protocol") }
        let versions = try root.required(root.array("versions"), "versions")
        guard !versions.isEmpty else { throw .invalid("versions") }
        self.versions = try versions.map { value throws(ReportDiscoveryProblem) in
            guard let literal = value.literal, literal.isInteger else { throw .invalid("versions") }
            return ReportClamp.integer(literal)
        }

        let service = try root.required(root.object("service"), "service")
        name = ReportPlainText.clean(try service.required(service.string("name"), "name"), limit: 40)
        guard !name.isEmpty else { throw .invalid("service.name") }
        summary = try service.string("description").map { ReportPlainText.clean($0, limit: 200) }.flatMap(Self.nonEmpty)
        homepage = try service.string("homepage").flatMap(ReportURLs.httpsLink)
        terms = try service.required(service.link("terms"), "terms")
        privacy = try service.required(service.link("privacy"), "privacy")
        leaderboard = try service.string("leaderboard").flatMap(ReportURLs.httpsLink)
        contact = try service.string("contact").map { ReportPlainText.clean($0, limit: 254) }.flatMap(Self.nonEmpty)
        retentionDays = try service.integer("retentionDays", in: 0...3650)

        extensions = ReportExtensions(root.members["extensions"])
        let apiText = try root.required(root.string("api"), "api")
        guard let api = ReportServiceURL.parseAPI(apiText, discoveryIsLoopbackHTTP: loopback) else { throw .invalid("api") }
        self.api = api

        let apiKey = try root.object("apiKey")
        if let mode = try apiKey?.string("mode") {
            guard let parsed = ReportAPIKeyMode(rawValue: mode) else { throw .invalid("apiKey.mode") }
            apiKeyMode = parsed
        } else {
            apiKeyMode = .none
        }
        apiKeyURL = try apiKey?.string("url").flatMap(ReportURLs.httpsLink)

        let username = try root.object("username")
        var charset = ReportUsernameRules.Charset.unicode
        if let text = try username?.string("charset") {
            guard let parsed = ReportUsernameRules.Charset(rawValue: text) else { throw .invalid("username.charset") }
            charset = parsed
        }
        usernameRules = ReportUsernameRules(
            minLength: try username?.integer("minLength", in: 1...12) ?? 2,
            maxLength: try username?.integer("maxLength", in: 12...32) ?? 32,
            charset: charset,
            spaces: try username?.bool("spaces") ?? true
        )

        let limits = try root.object("limits")
        self.limits = ReportLimits(
            intervalSeconds: try limits?.integer("intervalSeconds", in: 5...300) ?? 5,
            heartbeatSeconds: try limits?.integer("heartbeatSeconds", in: 30...900) ?? 60,
            maxAgeSeconds: try limits?.integer("maxAgeSeconds", in: 10...120) ?? 30,
            maxBodyBytes: try limits?.integer("maxBodyBytes", in: 4096...65_536) ?? 16_384,
            maxModels: try limits?.integer("maxModels", in: 0...16) ?? 16
        )

        if let names = try root.array("sections") {
            sections = []
            for item in names {
                guard let text = item.string else { throw .invalid("sections") }
                if let section = ReportSection(rawValue: text) { sections.insert(section) }
            }
        } else {
            sections = Set(ReportSection.allCases)
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// What the preview assumes before a service's document is known (DESIGN 11, Preview window): the API at the
    /// service URL, every section and the protocol's defaults. Never stored or confirmed; the real document can only
    /// list fewer sections.
    public static func assumed(for service: ReportServiceURL, name: String) -> ReportDiscovery? {
        let link = "https://\(service.host)/"
        let document = ReportJSON.object([
            "protocol": .string(protocolName), "versions": .array([.int(supportedVersion)]),
            "service": .object(["name": .string(name), "terms": .string(link), "privacy": .string(link)]),
            "api": .string(service.string),
        ])
        return try? parse(document.compactData, service: service).get()
    }
}

/// What the user confirmed in the consent sheet (REPORTING 3.3), stored with the identity.
public struct ReportConsentPin: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var terms: String
    public var privacy: String
    /// The normalized `api` string.
    public var api: String
    /// Sorted raw values.
    public var sections: [String]
    public var retentionDays: Int?
    public var apiKeyMode: ReportAPIKeyMode

    public init(_ discovery: ReportDiscovery) {
        name = discovery.name
        terms = discovery.terms.absoluteString
        privacy = discovery.privacy.absoluteString
        api = discovery.api.string
        sections = discovery.sections.map(\.rawValue).sorted()
        retentionDays = discovery.retentionDays
        apiKeyMode = discovery.apiKeyMode
    }

    /// REPORTING 3.3: true when `current` changes name, terms, privacy or api (after normalization, path included),
    /// adds a section, raises or removes retentionDays, or switches apiKey.mode to required while `hasAPIKey` is false.
    public func needsReview(_ current: ReportDiscovery, hasAPIKey: Bool) -> Bool {
        let now = ReportConsentPin(current)
        if !now.name.unicodeScalars.elementsEqual(name.unicodeScalars) || now.terms != terms || now.privacy != privacy
            || now.api != api {
            return true
        }
        if !Set(now.sections).isSubset(of: sections) { return true }
        if let confirmed = retentionDays, (now.retentionDays ?? Int.max) > confirmed { return true }
        return now.apiKeyMode == .required && apiKeyMode != .required && !hasAPIKey
    }
}

/// Plain text from a service (REPORTING 2.3): white space runs become one space, control and format characters
/// (bidirectional controls, U+200B …) are removed, the ends are trimmed and the length is capped in code points.
enum ReportPlainText {
    static func clean(_ text: String, limit: Int) -> String {
        var out: [Unicode.Scalar] = []
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if ReportUsername.isSpace(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate: continue
            default: break
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
        if out.count > limit { out = Array(out.prefix(limit)) }
        while out.last == " " { out.removeLast() }
        return String(String.UnicodeScalarView(out))
    }
}

enum ReportClamp {
    static func value(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// An integer literal, saturated at the `Int` limits.
    static func integer(_ literal: JSONLiteral) -> Int {
        if let value = literal.int64 { return Int(value) }
        return literal.text.hasPrefix("-") ? Int.min : Int.max
    }
}

/// One object of the discovery document. A present field of the wrong type is an error, a fraction where an integer
/// is expected included.
private struct DocumentFields {
    let members: [String: JSONValue]
    let path: String

    init(_ members: [String: JSONValue], path: String) {
        self.members = members
        self.path = path
    }

    func field(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    func required<T>(_ value: T?, _ key: String) throws(ReportDiscoveryProblem) -> T {
        guard let value else { throw .invalid(field(key)) }
        return value
    }

    func object(_ key: String) throws(ReportDiscoveryProblem) -> DocumentFields? {
        guard let value = members[key] else { return nil }
        guard let object = value.object else { throw .invalid(field(key)) }
        return DocumentFields(object, path: field(key))
    }

    func array(_ key: String) throws(ReportDiscoveryProblem) -> [JSONValue]? {
        guard let value = members[key] else { return nil }
        guard let array = value.array else { throw .invalid(field(key)) }
        return array
    }

    func string(_ key: String) throws(ReportDiscoveryProblem) -> String? {
        guard let value = members[key] else { return nil }
        guard let text = value.string else { throw .invalid(field(key)) }
        return text
    }

    func bool(_ key: String) throws(ReportDiscoveryProblem) -> Bool? {
        guard let value = members[key] else { return nil }
        guard let flag = value.bool else { throw .invalid(field(key)) }
        return flag
    }

    /// An integer, clamped to `range`; a fraction or an exponent is the wrong type (REPORTING 3.2).
    func integer(_ key: String, in range: ClosedRange<Int>) throws(ReportDiscoveryProblem) -> Int? {
        guard let value = members[key] else { return nil }
        guard let literal = value.literal, literal.isInteger else { throw .invalid(field(key)) }
        return ReportClamp.value(ReportClamp.integer(literal), range)
    }

    /// A required link: always `https`, also from a loopback test server (REPORTING 2.2).
    func link(_ key: String) throws(ReportDiscoveryProblem) -> URL? {
        guard let text = try string(key) else { return nil }
        guard let url = ReportURLs.httpsLink(text) else { throw .invalid(field(key)) }
        return url
    }
}
