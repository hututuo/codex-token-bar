import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Report service URLs")
struct ReportServiceURLTests {
    static func parsed(_ text: String) throws -> ReportServiceURL {
        try ReportServiceURL.parse(text).get()
    }

    @Test(arguments: [
        ("codexradar.com", "https://codexradar.com"),
        ("https://Example.com/", "https://example.com"),
        ("HTTPS://EXAMPLE.COM", "https://example.com"),
        ("  example.com  ", "https://example.com"),
        ("\texample.com\n", "https://example.com"),
        ("https://example.com/agentspeed/", "https://example.com/agentspeed"),
        ("https://example.com/AgentSpeed//", "https://example.com/AgentSpeed"),
        ("https://example.com:443", "https://example.com"),
        ("https://example.com:443/x", "https://example.com/x"),
        ("https://example.com:8443", "https://example.com:8443"),
        ("example.com:8443/board", "https://example.com:8443/board"),
        ("http://127.0.0.1:8787", "http://127.0.0.1:8787"),
        ("http://127.0.0.1:80/", "http://127.0.0.1"),
        ("http://[::1]:8787", "http://[::1]:8787"),
        ("http://LOCALHOST:8787/", "http://localhost:8787"),
        ("https://[2001:DB8::1]:8443/x", "https://[2001:db8::1]:8443/x"),
        ("https://bücher.example/x", "https://xn--bcher-kva.example/x"),
        ("https://BÜCHER.example", "https://xn--bcher-kva.example"),
        ("https://example.com/排行", "https://example.com/%E6%8E%92%E8%A1%8C"),
        ("https://example.com/a%2Fb", "https://example.com/a%2Fb"),
        ("localhost:8787", "https://localhost:8787"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try Self.parsed(input).string == expected)
    }

    @Test(arguments: [
        ("http://example.com", ReportURLProblem.notHTTPS),
        ("http://127.0.0.2:8787", .notHTTPS),
        ("http://localhost.example.com", .notHTTPS),
        ("ftp://example.com", .notHTTPS),
        ("ws://example.com", .notHTTPS),
        ("https://user@example.com", .invalid),
        ("https://user:secret@example.com", .invalid),
        ("https://example.com?q", .invalid),
        ("https://example.com/?", .invalid),
        ("https://example.com#f", .invalid),
        ("https://example.com/#", .invalid),
        ("", .invalid),
        ("   ", .invalid),
        ("https://", .invalid),
        ("https:///path", .invalid),
        ("https://exa mple.com", .invalid),
        ("https://example.com/a b", .invalid),
        ("https://exa\u{200B}mple.com", .invalid),
        ("https://example.com/\u{202E}x", .invalid),
        ("https://example.com\\x", .invalid),
        ("https://example.com/a\\b", .invalid),
        ("https://example.com/a%zz", .invalid),
        ("https://example.com/../x", .invalid),
        ("https://example.com/a/%2e%2E", .invalid),
        ("https://example.com/./x", .invalid),
        ("https://a..b", .invalid),
        ("https://example.com./x", .invalid),
        ("https://exa_mple.com", .invalid),
        ("https://-example.com", .invalid),
        ("https://ex%41mple.com", .invalid),
        ("https://example.com:0", .invalid),
        ("https://example.com:99999", .invalid),
        ("mailto:zoe@example.com", .invalid),
    ])
    func rejects(input: String, problem: ReportURLProblem) {
        #expect(ReportServiceURL.parse(input) == .failure(problem), "\(input)")
    }

    @Test func lengthIsCapped() throws {
        let base = "https://example.com/"
        let fits = base + String(repeating: "a", count: 2048 - base.count)
        #expect(try Self.parsed(fits).string.count == 2048)
        #expect(ReportServiceURL.parse(fits + "a") == .failure(.invalid))
    }

    @Test func derivedParts() throws {
        let plain = try Self.parsed("https://Example.com:8443/AgentSpeed/")
        #expect(plain.host == "example.com")
        #expect(plain.authority == "example.com:8443")
        #expect(plain.origin == "https://example.com:8443")
        #expect(!plain.isLoopbackHTTP)
        #expect(plain.url.absoluteString == "https://example.com:8443/AgentSpeed")

        let loopback = try Self.parsed("http://127.0.0.1:8787")
        #expect(loopback.isLoopbackHTTP)
        #expect(loopback.host == "127.0.0.1")
        #expect(loopback.authority == "127.0.0.1:8787")
        #expect(loopback.origin == "http://127.0.0.1:8787")

        let ipv6 = try Self.parsed("http://[::1]:8787")
        #expect(ipv6.isLoopbackHTTP && ipv6.host == "[::1]" && ipv6.authority == "[::1]:8787")
        #expect(!(try Self.parsed("https://localhost")).isLoopbackHTTP)
    }

    @Test func discoveryURLs() throws {
        #expect(try Self.parsed("https://example.com").discoveryURL.absoluteString
            == "https://example.com/.well-known/agent-speed-report")
        #expect(try Self.parsed("https://example.com/agentspeed").discoveryURL.absoluteString
            == "https://example.com/agentspeed/.well-known/agent-speed-report")
        #expect(try Self.parsed("http://127.0.0.1:8787/").discoveryURL.absoluteString
            == "http://127.0.0.1:8787/.well-known/agent-speed-report")
    }

    @Test func endpoints() throws {
        let api = try Self.parsed("https://api.example.com/agent-speed/")
        #expect(api.appending(endpoint: "/v1/reports").absoluteString == "https://api.example.com/agent-speed/v1/reports")
        let loopback = try Self.parsed("http://127.0.0.1:8787")
        #expect(loopback.appending(endpoint: "/v1/devices").absoluteString == "http://127.0.0.1:8787/v1/devices")
    }

    @Test func apiURLs() {
        #expect(ReportServiceURL.parseAPI("https://api.example.com/agent-speed/", discoveryIsLoopbackHTTP: false)?.string
            == "https://api.example.com/agent-speed")
        #expect(ReportServiceURL.parseAPI("https://API.example.com:443", discoveryIsLoopbackHTTP: false)?.string
            == "https://api.example.com")
        #expect(ReportServiceURL.parseAPI("http://127.0.0.1:8787", discoveryIsLoopbackHTTP: true)?.string
            == "http://127.0.0.1:8787")
        #expect(ReportServiceURL.parseAPI("https://api.example.com", discoveryIsLoopbackHTTP: true) != nil)
        #expect(ReportServiceURL.parseAPI("http://127.0.0.1:8787", discoveryIsLoopbackHTTP: false) == nil)
        #expect(ReportServiceURL.parseAPI("http://api.example.com", discoveryIsLoopbackHTTP: true) == nil)
        #expect(ReportServiceURL.parseAPI("api.example.com", discoveryIsLoopbackHTTP: false) == nil)
        #expect(ReportServiceURL.parseAPI(" https://api.example.com", discoveryIsLoopbackHTTP: false) == nil)
        #expect(ReportServiceURL.parseAPI("https://api.example.com/?x", discoveryIsLoopbackHTTP: false) == nil)
        #expect(ReportServiceURL.parseAPI("https://api.example.com/#x", discoveryIsLoopbackHTTP: false) == nil)
        #expect(ReportServiceURL.parseAPI("https://key@api.example.com", discoveryIsLoopbackHTTP: false) == nil)
    }

    @Test func requestVectorsAuthorityAndPath() throws {
        let requests = try #require(try Fixtures.json("report-vectors.json")["requests"] as? [String: [String: Any]])
        #expect(requests.count >= 6)
        for (name, request) in requests {
            let text = try #require(request["url"] as? String)
            let url = try #require(URL(string: text))
            #expect(ReportURLs.authority(of: url) == request["authority"] as? String, "\(name)")
            #expect(ReportURLs.requestPath(of: url) == request["path"] as? String, "\(name)")
        }
    }

    @Test func authorityAndPathRules() throws {
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }
        #expect(ReportURLs.authority(of: try url("https://API.Example.com:443/x")) == "api.example.com")
        #expect(ReportURLs.authority(of: try url("http://127.0.0.1:80/x")) == "127.0.0.1")
        #expect(ReportURLs.authority(of: try url("https://api.example.com:80/x")) == "api.example.com:80")
        #expect(ReportURLs.authority(of: try url("http://[::1]:8787/v1/reports")) == "[::1]:8787")
        #expect(ReportURLs.authority(of: try url("https://bücher.example/v1")) == "xn--bcher-kva.example")
        #expect(ReportURLs.requestPath(of: try url("https://example.com")) == "/")
        #expect(ReportURLs.requestPath(of: try url("https://example.com/a%2Fb/")) == "/a%2Fb/")
        #expect(ReportURLs.requestPath(of: try url("https://example.com/v1/x?a=1&b=%20")) == "/v1/x?a=1&b=%20")
    }

    @Test func httpsLinks() {
        #expect(ReportURLs.httpsLink("https://example.com/terms")?.absoluteString == "https://example.com/terms")
        #expect(ReportURLs.httpsLink("https://example.com/live?tab=now#top") != nil)
        #expect(ReportURLs.httpsLink("https://bücher.example/x") != nil)
        #expect(ReportURLs.httpsLink(nil) == nil)
        #expect(ReportURLs.httpsLink("") == nil)
        #expect(ReportURLs.httpsLink("http://example.com/terms") == nil)
        #expect(ReportURLs.httpsLink("http://127.0.0.1:8787/terms") == nil)
        #expect(ReportURLs.httpsLink("HTTPS://example.com") == nil)
        #expect(ReportURLs.httpsLink("javascript:alert(1)") == nil)
        #expect(ReportURLs.httpsLink("https://user@example.com/") == nil)
        #expect(ReportURLs.httpsLink("https://example.com?x") == nil)
        #expect(ReportURLs.httpsLink("https://example.com/a b") == nil)
        #expect(ReportURLs.httpsLink("https://example.com/\u{202E}gpj.exe") == nil)
        #expect(ReportURLs.httpsLink("https://") == nil)
        #expect(ReportURLs.httpsLink("https://example.com/" + String(repeating: "a", count: 2048)) == nil)
        #expect(ReportURLs.httpsLink("http://[::1]/terms") == nil, "links are https also from a loopback server")
        #expect(ReportURLs.httpsLink("http://localhost:8787/terms") == nil)
        #expect(ReportURLs.httpsLink("https://example.com/terms?lang=en#top") != nil)
    }

    @Test func codableAsItsString() throws {
        let original = try Self.parsed("https://api.example.com/agent-speed")
        let data = try JSONEncoder().encode(["api": original])
        #expect(String(decoding: data, as: UTF8.self) == #"{"api":"https:\/\/api.example.com\/agent-speed"}"#)
        #expect(try JSONDecoder().decode([String: ReportServiceURL].self, from: data)["api"] == original)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ReportServiceURL].self, from: Data(#"["http://example.com"]"#.utf8))
        }
    }

    @Test func equalityIsByNormalizedString() throws {
        #expect(try Self.parsed("https://Example.com/") == Self.parsed("example.com"))
        #expect(try Self.parsed("https://example.com/a") != Self.parsed("https://example.com/A"))
        #expect(Set([try Self.parsed("example.com"), try Self.parsed("https://example.com:443")]).count == 1)
    }
}
