import Foundation
import Testing
@testable import AgentSpeedCore

/// A JSON literal written verbatim into a test document (fractions, huge integers).
private struct RawLiteral {
    let text: String
}

@Suite("Report discovery")
struct ReportDiscoveryTests {
    static let repo = "https://github.com/zoefix/agent-speed"

    static func service(_ text: String = "https://example.com") throws -> ReportServiceURL {
        try ReportServiceURL.parse(text).get()
    }

    static func exampleData() throws -> Data {
        try Data(contentsOf: Fixtures.root.appendingPathComponent("report-examples/discovery.json"))
    }

    static func example() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: exampleData()) as? [String: Any])
    }

    /// `ReferenceService.discovery(scheme)` of `spec/tools/report_reference.py` for `127.0.0.1:8787`.
    static func reference(scheme: String = "http") -> [String: Any] {
        [
            "protocol": "agent-speed-report",
            "versions": [1],
            "service": [
                "name": "Agent Speed reference server",
                "description": "Local test server (spec/tools/report_server.py).",
                "terms": repo, "privacy": repo, "retentionDays": 0,
            ] as [String: Any],
            "api": "\(scheme)://127.0.0.1:8787",
            "apiKey": ["mode": "none"],
            "username": ["minLength": 2, "maxLength": 32, "charset": "unicode", "spaces": true] as [String: Any],
            "limits": ["intervalSeconds": 5, "heartbeatSeconds": 60, "maxAgeSeconds": 30, "maxBodyBytes": 16_384,
                       "maxModels": 16],
            "sections": ["sources", "models", "cost", "traffic"],
        ]
    }

    /// `document` with `path` (dotted) set to `value`, or removed when `value` is nil.
    static func edited(_ document: [String: Any], _ path: String, _ value: Any?) -> [String: Any] {
        var copy = document
        let keys = path.split(separator: ".").map(String.init)
        if keys.count == 1 {
            copy[keys[0]] = value
        } else {
            let child = copy[keys[0]] as? [String: Any] ?? [:]
            copy[keys[0]] = edited(child, keys.dropFirst().joined(separator: "."), value)
        }
        return copy
    }

    static func data(_ document: [String: Any]) throws -> Data {
        var raws: [String: String] = [:]
        func replacingRaw(_ value: Any) -> Any {
            switch value {
            case let raw as RawLiteral:
                let marker = "__raw_\(raws.count)__"
                raws[marker] = raw.text
                return marker
            case let object as [String: Any]: return object.mapValues(replacingRaw)
            case let array as [Any]: return array.map(replacingRaw)
            default: return value
            }
        }
        let prepared = replacingRaw(document)
        var text = String(decoding: try JSONSerialization.data(withJSONObject: prepared, options: [.sortedKeys]), as: UTF8.self)
        for (marker, literal) in raws { text = text.replacingOccurrences(of: "\"\(marker)\"", with: literal) }
        return Data(text.utf8)
    }

    static func parse(_ document: [String: Any], service: String = "https://example.com") throws
        -> Result<ReportDiscovery, ReportDiscoveryProblem>
    {
        ReportDiscovery.parse(try data(document), service: try Self.service(service))
    }

    static func parsed(_ document: [String: Any], service: String = "https://example.com") throws -> ReportDiscovery {
        try parse(document, service: service).get()
    }

    // MARK: - Valid documents

    @Test func exampleDocument() throws {
        let discovery = try ReportDiscovery.parse(Self.exampleData(), service: Self.service()).get()
        #expect(discovery.versions == [1])
        #expect(discovery.supportsThisClient)
        #expect(discovery.name == "Example Leaderboard")
        #expect(discovery.summary == "Live token speed of AI coding agents, updated every few seconds.")
        #expect(discovery.homepage?.absoluteString == "https://example.com/")
        #expect(discovery.terms.absoluteString == "https://example.com/terms")
        #expect(discovery.privacy.absoluteString == "https://example.com/privacy")
        #expect(discovery.leaderboard?.absoluteString == "https://example.com/live")
        #expect(discovery.contact == "privacy@example.com")
        #expect(discovery.retentionDays == 30)
        #expect(discovery.api.string == "https://api.example.com/agent-speed")
        #expect(discovery.apiKeyMode == .optional)
        #expect(discovery.apiKeyURL?.absoluteString == "https://example.com/account/keys")
        #expect(discovery.usernameRules == ReportUsernameRules(minLength: 2, maxLength: 24, charset: .unicode, spaces: true))
        #expect(discovery.limits == .standard)
        #expect(discovery.limits.sendLimitBytes == 16_384)
        #expect(discovery.sections == Set(ReportSection.allCases))
    }

    /// Codex Radar's live document (2026-10-23): the API on a sibling host with a path prefix, a section this client
    /// no longer sends, and no retention.
    @Test func codexRadarDocument() throws {
        let text = #"""
        {"protocol":"agent-speed-report","versions":[1],
         "service":{"name":"速蹬雷达","description":"社区贡献的实时速蹬天梯、全站吞吐与模型实测均速。",
          "homepage":"https://deng.codexradar.com/","terms":"https://deng.codexradar.com/agent-speed/terms/",
          "privacy":"https://deng.codexradar.com/agent-speed/privacy/","leaderboard":"https://deng.codexradar.com/",
          "retentionDays":0},
         "api":"https://speed-api.codexradar.com/api/agent-speed","apiKey":{"mode":"none"},
         "username":{"minLength":2,"maxLength":32,"charset":"unicode","spaces":true},
         "limits":{"intervalSeconds":5,"heartbeatSeconds":60,"maxAgeSeconds":30,"maxBodyBytes":16384,"maxModels":16},
         "sections":["sources","models","cost","traffic","machineTraffic"]}
        """#
        let discovery = try ReportDiscovery.parse(Data(text.utf8), service: Self.service("https://deng.codexradar.com")).get()
        #expect(discovery.name == "速蹬雷达")
        #expect(discovery.api.string == "https://speed-api.codexradar.com/api/agent-speed")
        #expect(discovery.api.host == "speed-api.codexradar.com")
        #expect(discovery.apiKeyMode == ReportAPIKeyMode.none)
        #expect(discovery.retentionDays == 0)
        #expect(discovery.sections == Set(ReportSection.allCases))
    }

    @Test func referenceServerDocumentOverLoopback() throws {
        let discovery = try Self.parsed(Self.reference(), service: "http://127.0.0.1:8787")
        #expect(discovery.name == "Agent Speed reference server")
        #expect(discovery.summary == "Local test server (spec/tools/report_server.py).")
        #expect(discovery.terms.absoluteString == Self.repo)
        #expect(discovery.privacy.absoluteString == Self.repo)
        #expect(discovery.retentionDays == 0)
        #expect(discovery.api.string == "http://127.0.0.1:8787")
        #expect(discovery.api.isLoopbackHTTP)
        #expect(discovery.api.appending(endpoint: "/v1/reports").absoluteString == "http://127.0.0.1:8787/v1/reports")
        #expect(discovery.apiKeyMode == .none && discovery.apiKeyURL == nil)
        #expect(discovery.usernameRules == .standard)
        #expect(discovery.limits == .standard)
        #expect(discovery.sections == Set(ReportSection.allCases))
        #expect(discovery.homepage == nil && discovery.leaderboard == nil && discovery.contact == nil)
    }

    @Test func minimalDocumentUsesDefaults() throws {
        let minimal: [String: Any] = [
            "protocol": "agent-speed-report", "versions": [1], "api": "https://api.example.com",
            "service": ["name": "Board", "terms": "https://example.com/t", "privacy": "https://example.com/p"],
        ]
        let discovery = try Self.parsed(minimal)
        #expect(discovery.summary == nil && discovery.retentionDays == nil && discovery.contact == nil)
        #expect(discovery.apiKeyMode == .none)
        #expect(discovery.usernameRules == .standard)
        #expect(discovery.limits == .standard)
        #expect(discovery.sections == Set(ReportSection.allCases))
    }

    @Test func sectionOrderFollowsTheSpec() {
        #expect(ReportSection.allCases.map(\.rawValue) == ["sources", "models", "cost", "traffic"])
    }

    @Test func unknownFieldsAreIgnored() throws {
        var document = try Self.example()
        document["future"] = ["anything": [1, 2, 3]]
        document = Self.edited(document, "service.logo", "https://example.com/logo.png")
        document = Self.edited(document, "limits.burst", 99)
        #expect(try Self.parsed(document).name == "Example Leaderboard")
    }

    @Test func versionsWithoutThisClient() throws {
        let discovery = try Self.parsed(Self.edited(Self.example(), "versions", [2, 3]))
        #expect(discovery.versions == [2, 3])
        #expect(!discovery.supportsThisClient)
    }

    @Test func sectionsListedByTheService() throws {
        let some = try Self.parsed(Self.edited(Self.example(), "sections", ["cost", "sources", "cost", "telemetry"]))
        #expect(some.sections == [.cost, .sources])
        #expect(try Self.parsed(Self.edited(Self.example(), "sections", [String]())).sections.isEmpty)
        #expect(try Self.parsed(Self.edited(Self.example(), "sections", nil)).sections == Set(ReportSection.allCases))
    }

    // MARK: - Clamping

    @Test func numbersAreClamped() throws {
        var document = try Self.example()
        for (path, value) in [
            ("limits.intervalSeconds", 1), ("limits.heartbeatSeconds", 5000), ("limits.maxAgeSeconds", 0),
            ("limits.maxBodyBytes", 1), ("limits.maxModels", -3), ("service.retentionDays", 99_999),
            ("username.minLength", 0), ("username.maxLength", 100),
        ] {
            document = Self.edited(document, path, value)
        }
        let discovery = try Self.parsed(document)
        #expect(discovery.limits == ReportLimits(
            intervalSeconds: 5, heartbeatSeconds: 900, maxAgeSeconds: 10, maxBodyBytes: 4096, maxModels: 0))
        #expect(discovery.limits.sendLimitBytes == 4096)
        #expect(discovery.retentionDays == 3650)
        #expect(discovery.usernameRules.minLength == 1 && discovery.usernameRules.maxLength == 32)

        var high = try Self.example()
        for (path, value) in [
            ("limits.intervalSeconds", 1000), ("limits.maxAgeSeconds", 500), ("limits.maxBodyBytes", 1_000_000),
            ("limits.maxModels", 99), ("service.retentionDays", -1), ("username.minLength", 20), ("username.maxLength", 1),
        ] {
            high = Self.edited(high, path, value)
        }
        let clamped = try Self.parsed(high)
        #expect(clamped.limits.intervalSeconds == 300 && clamped.limits.maxAgeSeconds == 120)
        #expect(clamped.limits.maxBodyBytes == 65_536 && clamped.limits.sendLimitBytes == 16_384)
        #expect(clamped.limits.maxModels == 16)
        #expect(clamped.retentionDays == 0)
        #expect(clamped.usernameRules.minLength == 12 && clamped.usernameRules.maxLength == 12)
    }

    @Test func heartbeatNeverBelowInterval() throws {
        var document = Self.edited(try Self.example(), "limits.intervalSeconds", 120)
        document = Self.edited(document, "limits.heartbeatSeconds", 30)
        #expect(try Self.parsed(document).limits.heartbeatSeconds == 120)
        #expect(ReportLimits(intervalSeconds: 300, heartbeatSeconds: 10).heartbeatSeconds == 300)
    }

    @Test func hugeIntegersSaturate() throws {
        var document = Self.edited(try Self.example(), "limits.maxBodyBytes", RawLiteral(text: "100000000000000000000000000000"))
        document = Self.edited(document, "service.retentionDays", RawLiteral(text: "-100000000000000000000000000000"))
        let discovery = try Self.parsed(document)
        #expect(discovery.limits.maxBodyBytes == 65_536)
        #expect(discovery.retentionDays == 0)
    }

    /// REPORTING 3.2: a number that is not an integer literal (a fraction or an exponent) where an integer is expected
    /// is the wrong type, so the document is invalid.
    @Test(arguments: [
        ("limits.intervalSeconds", "7.5"), ("limits.heartbeatSeconds", "120.0"), ("limits.maxModels", "1e1"),
        ("service.retentionDays", "30.0"), ("username.maxLength", "20.5"),
    ])
    func nonIntegerNumbersAreInvalid(path: String, literal: String) throws {
        let document = Self.edited(try Self.example(), path, RawLiteral(text: literal))
        #expect(try Self.parse(document) == .failure(.invalid(path)))
    }

    @Test func limitsAndRulesDecodeClamped() throws {
        let limits = try JSONDecoder().decode(ReportLimits.self, from: Data(#"{"intervalSeconds": 1, "maxBodyBytes": 1}"#.utf8))
        #expect(limits == ReportLimits(intervalSeconds: 5, maxBodyBytes: 4096))
        #expect(ReportLimits.standard == ReportLimits(
            intervalSeconds: 5, heartbeatSeconds: 60, maxAgeSeconds: 30, maxBodyBytes: 16_384, maxModels: 16))
    }

    // MARK: - Text and links

    @Test func textIsPlainAndCapped() throws {
        var document = Self.edited(try Self.example(), "service.name", "  Speed\u{202E}\u{200B} \n\t Board\u{0007} ")
        document = Self.edited(document, "service.description", String(repeating: "word ", count: 100))
        document = Self.edited(document, "service.contact", String(repeating: "c", count: 300))
        let discovery = try Self.parsed(document)
        #expect(discovery.name == "Speed Board")
        #expect(discovery.summary?.unicodeScalars.count == 199)
        #expect(discovery.summary?.hasSuffix("word") == true)
        #expect(discovery.contact?.count == 254)

        let long = try Self.parsed(Self.edited(try Self.example(), "service.name", String(repeating: "名", count: 50)))
        #expect(long.name.unicodeScalars.count == 40)
        #expect(ReportPlainText.clean("a\u{2066}b\u{2069}\u{FEFF}c\u{2028}d", limit: 40) == "abc d")
    }

    @Test func emptyOptionalTextIsNil() throws {
        var document = Self.edited(try Self.example(), "service.description", " \u{200B} ")
        document = Self.edited(document, "service.contact", "")
        let discovery = try Self.parsed(document)
        #expect(discovery.summary == nil && discovery.contact == nil)
    }

    @Test func optionalLinksThatAreNotHTTPSAreDropped() throws {
        var document = Self.edited(try Self.example(), "service.homepage", "http://example.com/")
        document = Self.edited(document, "service.leaderboard", "javascript:alert(1)")
        document = Self.edited(document, "apiKey.url", "ftp://example.com/keys")
        let discovery = try Self.parsed(document)
        #expect(discovery.homepage == nil && discovery.leaderboard == nil && discovery.apiKeyURL == nil)
        #expect(discovery.name == "Example Leaderboard")

        let loopback = Self.edited(Self.reference(), "service.leaderboard", "http://127.0.0.1:8787/live")
        #expect(try Self.parsed(loopback, service: "http://127.0.0.1:8787").leaderboard == nil)
    }

    /// Links are always https; only `api` may use the loopback exception (REPORTING 2.2).
    @Test func loopbackLinksAreInvalid() throws {
        let terms = Self.edited(Self.reference(), "service.terms", "http://127.0.0.1:8787/terms")
        #expect(try Self.parse(terms, service: "http://127.0.0.1:8787") == .failure(.invalid("service.terms")))
        let privacy = Self.edited(Self.reference(), "service.privacy", "http://localhost:8787/privacy")
        #expect(try Self.parse(privacy, service: "http://127.0.0.1:8787") == .failure(.invalid("service.privacy")))
        #expect(try Self.parsed(Self.reference(), service: "http://127.0.0.1:8787").api.string == "http://127.0.0.1:8787")
    }

    @Test func apiIsNormalized() throws {
        let discovery = try Self.parsed(Self.edited(try Self.example(), "api", "https://API.Example.com:443/agent-speed/"))
        #expect(discovery.api.string == "https://api.example.com/agent-speed")
        #expect(try Self.parsed(Self.reference(scheme: "https"), service: "http://127.0.0.1:8787").api.string
            == "https://127.0.0.1:8787")
    }

    // MARK: - Vectors

    /// report-vectors.json `discovery` (REPORTING 2.2, 3.2): defaults, clamping, dropped links, the loopback rule and
    /// the first invalid field, as `parse_discovery` of the reference sees them.
    @Test func vectorCases() throws {
        let vectors = try Fixtures.json("report-vectors.json")
        let cases = try #require(vectors["discovery"] as? [[String: Any]])
        #expect(cases.count == 15)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let fetched = try #require(item["fetchedFrom"] as? String)
            let service = try ReportServiceURL.parse(fetched.replacingOccurrences(of: "/.well-known/agent-speed-report", with: "")).get()
            let data = try JSONSerialization.data(withJSONObject: item["document"] ?? [:])
            let expect = try #require(item["expect"] as? [String: Any])
            switch ReportDiscovery.parse(data, service: service) {
            case .failure(.invalid(let field)):
                #expect(expect["invalid"] as? String == field, "\(name)")
            case .failure(let problem):
                Issue.record("\(name): \(problem)")
            case .success(let discovery):
                #expect(expect["invalid"] == nil, "\(name): accepted")
                for (key, value) in expect {
                    #expect(Self.field(key, of: discovery) == Self.text(value), "\(name): \(key)")
                }
            }
        }
    }

    /// The reference's name for a parsed field, as comparable text.
    private static func field(_ key: String, of discovery: ReportDiscovery) -> String {
        switch key {
        case "api": discovery.api.string
        case "apiKeyMode": discovery.apiKeyMode.rawValue
        case "apiKeyUrl": discovery.apiKeyURL?.absoluteString ?? "null"
        case "homepage": discovery.homepage?.absoluteString ?? "null"
        case "leaderboard": discovery.leaderboard?.absoluteString ?? "null"
        case "retentionDays": discovery.retentionDays.map(String.init) ?? "null"
        case "sections": ReportSection.allCases.filter(discovery.sections.contains).map(\.rawValue).joined(separator: ",")
        case "limits":
            [("heartbeatSeconds", discovery.limits.heartbeatSeconds), ("intervalSeconds", discovery.limits.intervalSeconds),
             ("maxAgeSeconds", discovery.limits.maxAgeSeconds), ("maxBodyBytes", discovery.limits.maxBodyBytes),
             ("maxModels", discovery.limits.maxModels)].map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        case "username":
            [("charset", discovery.usernameRules.charset.rawValue), ("maxLength", String(discovery.usernameRules.maxLength)),
             ("minLength", String(discovery.usernameRules.minLength)), ("spaces", String(discovery.usernameRules.spaces))]
                .map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        default: "unknown key \(key)"
        }
    }

    private static func text(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let list as [String]: return list.joined(separator: ",")
        case let object as [String: Any]:
            return object.keys.sorted().map { key in
                let item = object[key]!
                if let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return "\(key)=\(number.boolValue)"
                }
                return "\(key)=\(item)"
            }.joined(separator: ",")
        default: return "\(value)"
        }
    }

    // MARK: - Invalid documents

    @Test(arguments: [
        ("protocol", "protocol"), ("versions", "versions"), ("service", "service"), ("service.name", "service.name"),
        ("service.terms", "service.terms"), ("service.privacy", "service.privacy"), ("api", "api"),
    ])
    func missingRequiredField(path: String, field: String) throws {
        #expect(try Self.parse(Self.edited(Self.example(), path, nil)) == .failure(.invalid(field)))
    }

    @Test(arguments: [
        ("protocol", #""agent-speed""#, "protocol"),
        ("protocol", "1", "protocol"),
        ("versions", "[]", "versions"),
        ("versions", "1", "versions"),
        ("versions", #"["1"]"#, "versions"),
        ("versions", "[1.5]", "versions"),
        ("service", #""Example""#, "service"),
        ("service.name", "5", "service.name"),
        ("service.name", #"" ​‮ ""#, "service.name"),
        ("service.description", "5", "service.description"),
        ("service.homepage", #"["https://example.com"]"#, "service.homepage"),
        ("service.terms", #""http://example.com/terms""#, "service.terms"),
        ("service.terms", #""example.com/terms""#, "service.terms"),
        ("service.privacy", #""https://user@example.com/privacy""#, "service.privacy"),
        ("service.contact", "null", "service.contact"),
        ("service.retentionDays", #""30""#, "service.retentionDays"),
        ("service.retentionDays", "true", "service.retentionDays"),
        ("api", #""http://127.0.0.1:8787""#, "api"),
        ("api", #""http://api.example.com""#, "api"),
        ("api", #""https://api.example.com/?v=1""#, "api"),
        ("api", #""https://api.example.com/#x""#, "api"),
        ("api", #""https://key@api.example.com""#, "api"),
        ("api", #""api.example.com""#, "api"),
        ("api", "443", "api"),
        ("apiKey", #""required""#, "apiKey"),
        ("apiKey.mode", #""sometimes""#, "apiKey.mode"),
        ("apiKey.mode", "1", "apiKey.mode"),
        ("username", "[1]", "username"),
        ("username.charset", #""latin""#, "username.charset"),
        ("username.spaces", #""yes""#, "username.spaces"),
        ("username.minLength", #""2""#, "username.minLength"),
        ("limits", "5", "limits"),
        ("limits.intervalSeconds", #""5""#, "limits.intervalSeconds"),
        ("limits.maxModels", "null", "limits.maxModels"),
        ("sections", #""cost""#, "sections"),
        ("sections", #"["cost", 1]"#, "sections"),
    ])
    func invalidField(path: String, json: String, field: String) throws {
        let document = Self.edited(try Self.example(), path, RawLiteral(text: json))
        #expect(try Self.parse(document) == .failure(.invalid(field)))
    }

    @Test func httpAPIFromAnHTTPSService() throws {
        #expect(try Self.parse(Self.reference(), service: "https://example.com") == .failure(.invalid("api")))
        #expect(try Self.parse(Self.reference(), service: "https://127.0.0.1:8787") == .failure(.invalid("api")))
    }

    @Test func notJSON() throws {
        let service = try Self.service()
        #expect(ReportDiscovery.parse(Data("not json".utf8), service: service) == .failure(.notJSON))
        #expect(ReportDiscovery.parse(Data("[1]".utf8), service: service) == .failure(.notJSON))
        #expect(ReportDiscovery.parse(Data(), service: service) == .failure(.notJSON))
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + (try Self.exampleData())
        #expect(ReportDiscovery.parse(withBOM, service: service) == .failure(.notJSON))
    }

    @Test func sizeLimit() throws {
        let service = try Self.service()
        let base = try Self.exampleData()
        let exact = base + Data(repeating: 0x20, count: ReportDiscovery.maxBytes - base.count)
        #expect(exact.count == 65_536)
        #expect((try? ReportDiscovery.parse(exact, service: service).get()) != nil)
        #expect(ReportDiscovery.parse(exact + Data([0x20]), service: service) == .failure(.tooLarge))
    }

    @Test func codableRoundTrip() throws {
        let discovery = try ReportDiscovery.parse(Self.exampleData(), service: Self.service()).get()
        let data = try JSONEncoder().encode(discovery)
        #expect(try JSONDecoder().decode(ReportDiscovery.self, from: data) == discovery)
    }

    // MARK: - Consent pinning

    static func pinned() throws -> (ReportConsentPin, [String: Any]) {
        let document = try example()
        return (ReportConsentPin(try parsed(document)), document)
    }

    static func review(_ path: String, _ value: Any?, hasAPIKey: Bool = false) throws -> Bool {
        let (pin, document) = try pinned()
        return pin.needsReview(try parsed(edited(document, path, value)), hasAPIKey: hasAPIKey)
    }

    @Test func pinContents() throws {
        let (pin, _) = try Self.pinned()
        #expect(pin.name == "Example Leaderboard")
        #expect(pin.terms == "https://example.com/terms" && pin.privacy == "https://example.com/privacy")
        #expect(pin.api == "https://api.example.com/agent-speed")
        #expect(pin.sections == ["cost", "models", "sources", "traffic"])
        #expect(pin.retentionDays == 30 && pin.apiKeyMode == .optional)
        let decoded = try JSONDecoder().decode(ReportConsentPin.self, from: JSONEncoder().encode(pin))
        #expect(decoded == pin)
    }

    @Test func unchangedDocumentNeedsNoReview() throws {
        let (pin, document) = try Self.pinned()
        #expect(!pin.needsReview(try Self.parsed(document), hasAPIKey: false))
        #expect(!pin.needsReview(try Self.parsed(document), hasAPIKey: true))
    }

    @Test func detailChangesNeedReview() throws {
        #expect(try Self.review("service.name", "Example Board"))
        #expect(try Self.review("service.terms", "https://example.com/terms-2026"))
        #expect(try Self.review("service.privacy", "https://example.org/privacy"))
        #expect(try Self.review("api", "https://collect.example.com/agent-speed"))
        #expect(try Self.review("api", "https://api.example.com/agent-speed/v2"))
        #expect(try Self.review("api", "https://api.example.com:8443/agent-speed"))
    }

    @Test func equivalentDetailsNeedNoReview() throws {
        #expect(try !Self.review("service.name", "  Example\u{200B} Leaderboard "))
        #expect(try !Self.review("api", "https://API.example.com:443/agent-speed/"))
    }

    @Test func sectionChanges() throws {
        let (pin, document) = try Self.pinned()
        let fewer = try Self.parsed(Self.edited(document, "sections", ["cost", "sources"]))
        #expect(!pin.needsReview(fewer, hasAPIKey: false))
        let narrowPin = ReportConsentPin(fewer)
        #expect(narrowPin.needsReview(try Self.parsed(Self.edited(document, "sections", ["cost", "sources", "models"])),
                                      hasAPIKey: false))
        #expect(!narrowPin.needsReview(try Self.parsed(Self.edited(document, "sections", ["sources", "unknown"])),
                                       hasAPIKey: false))
    }

    @Test func retentionChanges() throws {
        #expect(try Self.review("service.retentionDays", 31))
        #expect(try Self.review("service.retentionDays", nil))
        #expect(try !Self.review("service.retentionDays", 7))
        #expect(try !Self.review("service.retentionDays", 30))

        let (_, document) = try Self.pinned()
        let unstated = ReportConsentPin(try Self.parsed(Self.edited(document, "service.retentionDays", nil)))
        #expect(!unstated.needsReview(try Self.parsed(document), hasAPIKey: false))
    }

    @Test func apiKeyModeChanges() throws {
        #expect(try Self.review("apiKey.mode", "required", hasAPIKey: false))
        #expect(try !Self.review("apiKey.mode", "required", hasAPIKey: true))
        #expect(try !Self.review("apiKey.mode", "none"))
        #expect(try !Self.review("apiKey", nil))

        let (_, document) = try Self.pinned()
        let required = Self.edited(document, "apiKey.mode", "required")
        let requiredPin = ReportConsentPin(try Self.parsed(required))
        #expect(!requiredPin.needsReview(try Self.parsed(required), hasAPIKey: false))
    }

    @Test func otherChangesApplySilently() throws {
        #expect(try !Self.review("limits", ["intervalSeconds": 30, "heartbeatSeconds": 300, "maxModels": 4]))
        #expect(try !Self.review("service.description", "Something else entirely."))
        #expect(try !Self.review("service.description", nil))
        #expect(try !Self.review("service.leaderboard", "https://example.com/board"))
        #expect(try !Self.review("service.homepage", nil))
        #expect(try !Self.review("service.contact", "https://example.com/contact"))
        #expect(try !Self.review("username", ["minLength": 4, "maxLength": 16, "charset": "ascii", "spaces": false]))
        #expect(try !Self.review("apiKey.url", "https://example.com/keys"))
        #expect(try !Self.review("versions", [1, 2]))
    }
}
