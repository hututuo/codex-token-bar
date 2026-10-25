import Foundation
import os
import Testing
@testable import AgentSpeedCore

/// The dashboard invitation (DESIGN 11) and one-click consent (REPORTING 3.3).
@Suite("Report invitation")
struct ReportInviteTests {
    static let offered = ReportInvite.Context(answer: nil, reportingEnabled: false, networkEnabled: true,
                                              presetSelected: true, hasRegisteredIdentity: false)

    @Test func offeredOnlyWhileUnansweredOffOnlineOnThePresetAndUnregistered() {
        #expect(ReportInvite.isOffered(Self.offered))
        var context = Self.offered
        for answer in [ReportInvite.Answer.accepted, .declined] {
            context.answer = answer
            #expect(!ReportInvite.isOffered(context), "answered \(answer) never shows again")
        }
        context = Self.offered
        context.reportingEnabled = true
        #expect(!ReportInvite.isOffered(context), "reporting already on")
        context = Self.offered
        context.networkEnabled = false
        #expect(!ReportInvite.isOffered(context), "network master switch off")
        context = Self.offered
        context.presetSelected = false
        #expect(!ReportInvite.isOffered(context), "a custom service")
        context = Self.offered
        context.hasRegisteredIdentity = true
        #expect(!ReportInvite.isOffered(context), "already registered somewhere")
    }

    @Test func answerRoundTripsAsItsRawValue() throws {
        for answer in [ReportInvite.Answer.accepted, .declined] {
            let data = try JSONEncoder().encode(answer)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(answer.rawValue)\"")
            #expect(try JSONDecoder().decode(ReportInvite.Answer.self, from: data) == answer)
        }
    }

    static func document(api: String = "https://codexradar.com", apiKey: String = "none",
                         username: [String: Any] = [:]) throws -> ReportDiscovery {
        let object: [String: Any] = [
            "protocol": "agent-speed-report", "versions": [1],
            "service": ["name": "Codex Radar", "terms": "https://codexradar.com/terms",
                        "privacy": "https://codexradar.com/privacy"] as [String: Any],
            "api": api, "apiKey": ["mode": apiKey], "username": username,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ReportDiscovery.parse(data, service: Self.service).get()
    }

    static let service = try! ReportServiceURL.parse("https://codexradar.com").get()

    @Test func theInvitationCoversTheServiceHostAndItsSubdomains() throws {
        #expect(ReportInvite.gap(try Self.document(), service: Self.service, username: "Zoes MacBook Pro") == nil)
        #expect(ReportInvite.gap(try Self.document(api: "https://api.codexradar.com/v"), service: Self.service,
                                 username: "zoe") == nil)
        #expect(ReportInvite.gap(try Self.document(api: "https://codexradar.workers.dev"), service: Self.service,
                                 username: "zoe") == .apiHost)
        #expect(ReportInvite.gap(try Self.document(api: "https://evilcodexradar.com"), service: Self.service,
                                 username: "zoe") == .apiHost)
    }

    @Test func thePresetDomainCoversItsSiblingAPIHost() throws {
        let deng = try ReportServiceURL.parse("https://deng.codexradar.com").get()
        let object: [String: Any] = [
            "protocol": "agent-speed-report", "versions": [1],
            "service": ["name": "速蹬雷达", "terms": "https://deng.codexradar.com/agent-speed/terms/",
                        "privacy": "https://deng.codexradar.com/agent-speed/privacy/"] as [String: Any],
            "api": "https://speed-api.codexradar.com/api/agent-speed", "apiKey": ["mode": "none"],
        ]
        let document = try ReportDiscovery.parse(try JSONSerialization.data(withJSONObject: object), service: deng).get()
        #expect(ReportInvite.gap(document, service: deng, username: "zoe") == .apiHost, "a sibling host needs the preset")
        #expect(ReportInvite.gap(document, service: deng, username: "zoe", presetDomain: "codexradar.com") == nil)
        let other = try ReportServiceURL.parse("https://example.com").get()
        #expect(ReportInvite.gap(document, service: other, username: "zoe", presetDomain: "codexradar.com") == .apiHost,
                "the preset domain only covers a service URL inside it")
    }

    @Test func subdomainsOfAnIPAddressDoNotExist() {
        #expect(ReportInvite.covers(apiHost: "127.0.0.1", serviceHost: "127.0.0.1"))
        #expect(!ReportInvite.covers(apiHost: "1.127.0.0.1", serviceHost: "127.0.0.1"))
        #expect(ReportInvite.covers(apiHost: "API.Example.com", serviceHost: "example.com"))
        #expect(!ReportInvite.covers(apiHost: "example.com", serviceHost: "api.example.com"))
    }

    @Test func aRequiredKeyOrAUsernameTheRulesRejectNeedsTheSheet() throws {
        #expect(ReportInvite.gap(try Self.document(apiKey: "required"), service: Self.service, username: "zoe") == .apiKey)
        #expect(ReportInvite.gap(try Self.document(apiKey: "optional"), service: Self.service, username: "zoe") == nil)
        let ascii = try Self.document(username: ["charset": "ascii", "spaces": false])
        #expect(ReportInvite.gap(ascii, service: Self.service, username: "小明的 MacBook Pro") == .username(.characters))
        #expect(ReportInvite.gap(ascii, service: Self.service, username: "Zoes-MacBook-Pro") == nil)
    }

    /// Before the document is known the field is checked against the protocol grammar with the default lengths
    /// (REPORTING 4.3): names most services accept pass, symbols never do.
    @Test func namesBeforeTheDocumentFollowTheProtocolGrammar() {
        #expect(ReportUsername.validate("小明的 MacBook Pro", rules: .standard) == nil)
        #expect(ReportUsername.validate("Zoes MacBook Pro", rules: .standard) == nil)
        #expect(ReportUsername.validate("zoe 🚀", rules: .standard) == .characters)
        #expect(ReportUsername.validate("z", rules: .standard) == .length)
    }

    @Test func thePreviewAssumesTheProtocolDefaults() throws {
        let assumed = try #require(ReportDiscovery.assumed(for: Self.service, name: "Codex Radar"))
        #expect(assumed.api == Self.service)
        #expect(assumed.sections == Set(ReportSection.allCases))
        #expect(assumed.limits == .standard && assumed.usernameRules == .standard && assumed.apiKeyMode == .none)
        let loopback = try ReportServiceURL.parse("http://127.0.0.1:8787").get()
        #expect(ReportDiscovery.assumed(for: loopback, name: "Local")?.api == loopback)
    }
}

/// Every discovery failure becomes one plain outcome (REPORTING 3.1, 3.2; DESIGN 11, Service); nothing technical
/// reaches the user.
@Suite("Report discovery failures")
struct ReportDiscoveryFailureTests {
    static let service = try! ReportServiceURL.parse("https://codexradar.com").get()

    static func outcome(_ status: Int, _ body: String = "", etag: String? = nil) -> ReportAPI.DiscoveryOutcome {
        ReportAPI.discoveryOutcome(status: status, body: Data(body.utf8), etag: etag, responseETag: nil,
                                   service: service)
    }

    @Test func statusesMapToPlainOutcomes() {
        #expect(Self.outcome(404) == .notSupported)
        #expect(Self.outcome(403) == .notSupported)
        #expect(Self.outcome(401) == .notSupported)
        #expect(Self.outcome(410) == .gone)
        #expect(Self.outcome(429) == .failed(.unavailable))
        #expect(Self.outcome(500) == .failed(.unavailable))
        #expect(Self.outcome(503) == .failed(.unavailable))
        #expect(Self.outcome(302) == .failed(.unavailable))
        #expect(Self.outcome(304) == .failed(.unavailable), "304 without an ETag of ours")
        #expect(Self.outcome(304, etag: "\"v1\"") == .notModified)
    }

    @Test func aWebPageOrOtherJSONIsNotSupportedAndABrokenDocumentIsInvalid() {
        #expect(Self.outcome(200, "<!doctype html><html><body>Codex Radar</body></html>") == .notSupported)
        #expect(Self.outcome(200, "[1, 2]") == .notSupported)
        #expect(Self.outcome(200, #"{"name": "something else"}"#) == .notSupported)
        #expect(Self.outcome(200, #"{"protocol": "other", "versions": [1]}"#) == .notSupported)
        let missingTerms = #"{"protocol": "agent-speed-report", "versions": [1], "service": {"name": "X", "privacy": "https://x.test/p"}, "api": "https://x.test"}"#
        #expect(Self.outcome(200, missingTerms) == .invalid)
        #expect(Self.outcome(200, String(repeating: " ", count: ReportDiscovery.maxBytes + 1)) == .notSupported)
    }

    @Test func transportErrorsMapToPlainFailures() {
        #expect(ReportTransportError.timeout.failure == .unreachable)
        #expect(ReportTransportError.offline.failure == .unreachable)
        #expect(ReportTransportError.other(-1).failure == .unreachable)
        #expect(ReportTransportError.tls.failure == .insecure)
        #expect(ReportTransportError.disallowedRedirect.failure == .insecure)
        #expect(ReportTransportError.tooLarge.failure == .response)
        for failure in [ReportFailure.unreachable, .insecure, .unavailable, .response, .key] {
            #expect(failure.key == "report.error.\(failure.rawValue)")
        }
    }

    /// The case the user met: the service URL answers with its (large) web page.
    @Test func aLargeWebPageIsNotSupportedThroughTheRealTransport() async {
        let url = Self.service.discoveryURL
        DiscoveryStub.set(url, status: 200, body: Data(repeating: UInt8(ascii: "a"), count: 200_000),
                          headers: ["Content-Type": "text/html"])
        let api = ReportAPI(transport: URLSessionReportTransport(protocolClasses: [DiscoveryStub.self]),
                            userAgent: "AgentSpeed/1.3.0 (macOS)")
        #expect(await api.discover(Self.service) == .notSupported)
        DiscoveryStub.set(url, status: 200, body: Data("<html>small page</html>".utf8), headers: ["Content-Type": "text/html"])
        #expect(await api.discover(Self.service) == .notSupported)
        DiscoveryStub.set(url, status: 502, body: Data("Bad gateway".utf8), headers: [:])
        #expect(await api.discover(Self.service) == .failed(.unavailable))
    }
}

/// Serves one scripted discovery response inside the URL loading system; nothing leaves the process.
private final class DiscoveryStub: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    private static let stubs = OSAllocatedUnfairLock<[String: Stub]>(initialState: [:])

    static func set(_ url: URL, status: Int, body: Data, headers: [String: String]) {
        stubs.withLock { $0[url.absoluteString] = Stub(status: status, body: body, headers: headers) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stubs.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < stub.body.count {
            let end = min(stub.body.count, offset + 16_384)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
