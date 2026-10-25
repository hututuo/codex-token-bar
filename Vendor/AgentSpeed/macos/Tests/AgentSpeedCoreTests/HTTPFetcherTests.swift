import Foundation
import os
import Testing
@testable import AgentSpeedCore

/// Serves scripted responses inside the URL loading system, so `URLSessionTransport` runs for real without network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var redirect: URL?
    }

    private static let stubs = OSAllocatedUnfairLock<[String: Stub]>(initialState: [:])
    private static let seen = OSAllocatedUnfairLock<[String: [String: String]]>(initialState: [:])

    static func set(_ url: URL, _ stub: Stub) { stubs.withLock { $0[url.absoluteString] = stub } }
    static func headers(of url: URL) -> [String: String]? { seen.withLock { $0[url.absoluteString] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stubs.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.seen.withLock { $0[url.absoluteString] = request.allHTTPHeaderFields ?? [:] }
        if let target = stub.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HTTP fetcher")
struct HTTPFetcherTests {
    static let transport = URLSessionTransport(protocolClasses: [StubProtocol.self])

    static func request(_ url: URL, maxBytes: Int = 1024, hosts: Set<String> = ["a.test", "b.test"], etag: String? = nil) -> HTTPFetchRequest {
        HTTPFetchRequest(url: url, ifNoneMatch: etag, userAgent: "AgentSpeed/1.0.0 (macOS)", maxBytes: maxBytes, allowedHosts: hosts)
    }

    @Test func onlyHTTPSOnTheHostListIsAsked() async {
        for url in ["http://a.test/x", "https://c.test/x", "https://user@a.test/x", "https://a.test:8443/x"] {
            await #expect(throws: HTTPFetchError.disallowedURL) {
                try await Self.transport.get(Self.request(URL(string: url)!))
            }
        }
    }

    @Test func aResponseWithItsETagAndOnlyTheAllowedHeaders() async throws {
        let url = URL(string: "https://a.test/ok")!
        StubProtocol.set(url, .init(headers: ["ETag": "\"abc\"", "Content-Length": "5"], chunks: [Data("hello".utf8)]))
        let response = try await Self.transport.get(Self.request(url, etag: "\"old\""))
        #expect(response.status == 200)
        #expect(response.body == Data("hello".utf8))
        #expect(response.etag == "\"abc\"")
        let headers = try #require(StubProtocol.headers(of: url))
        #expect(headers["User-Agent"] == "AgentSpeed/1.0.0 (macOS)")
        #expect(headers["Accept"] == "application/json")
        #expect(headers["If-None-Match"] == "\"old\"")
        #expect(headers["Accept-Language"] == "*")
        #expect(headers["Cookie"] == nil)
    }

    @Test func notModifiedIsAnOrdinaryResponse() async throws {
        let url = URL(string: "https://a.test/304")!
        StubProtocol.set(url, .init(status: 304, headers: ["ETag": "\"abc\""]))
        let response = try await Self.transport.get(Self.request(url, etag: "\"abc\""))
        #expect(response.status == 304)
        #expect(response.body.isEmpty)
    }

    @Test func errorStatusesAreReturnedWithoutTheirBody() async throws {
        let url = URL(string: "https://a.test/404")!
        StubProtocol.set(url, .init(status: 404, chunks: [Data("nope".utf8)]))
        let response = try await Self.transport.get(Self.request(url))
        #expect(response.status == 404)
        #expect(response.body.isEmpty)
    }

    @Test func theCapAppliesToContentLengthAndToTheStream() async {
        let declared = URL(string: "https://a.test/declared")!
        StubProtocol.set(declared, .init(headers: ["Content-Length": "2048"], chunks: [Data(count: 2048)]))
        await #expect(throws: HTTPFetchError.tooLarge) { try await Self.transport.get(Self.request(declared)) }
        let streamed = URL(string: "https://a.test/streamed")!
        StubProtocol.set(streamed, .init(chunks: [Data(count: 600), Data(count: 600)]))
        await #expect(throws: HTTPFetchError.tooLarge) { try await Self.transport.get(Self.request(streamed)) }
    }

    @Test func redirectsStayOnTheHostList() async throws {
        let away = URL(string: "https://a.test/away")!
        StubProtocol.set(away, .init(redirect: URL(string: "https://evil.test/x")!))
        await #expect(throws: HTTPFetchError.disallowedURL) { try await Self.transport.get(Self.request(away)) }
        let downgrade = URL(string: "https://a.test/downgrade")!
        StubProtocol.set(downgrade, .init(redirect: URL(string: "http://b.test/x")!))
        await #expect(throws: HTTPFetchError.disallowedURL) { try await Self.transport.get(Self.request(downgrade)) }
        let hop = URL(string: "https://a.test/hop")!
        let target = URL(string: "https://b.test/target")!
        StubProtocol.set(hop, .init(redirect: target))
        StubProtocol.set(target, .init(chunks: [Data("{}".utf8)]))
        let response = try await Self.transport.get(Self.request(hop))
        #expect(response.body == Data("{}".utf8))
        #expect(response.finalURL == target)
    }
}
