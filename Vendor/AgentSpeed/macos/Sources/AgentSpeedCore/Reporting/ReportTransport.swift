import Foundation

/// A response of any status with its (capped) body; header names lower-case.
public struct ReportHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), finalURL: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

public enum ReportTransportError: Error, Equatable, Sendable {
    /// A redirect to a non-https URL, or more than three (discovery).
    case disallowedRedirect
    case tooLarge
    case timeout
    case offline
    case tls
    case other(Int)

    /// A short reason for the log only (REPORTING 2.3); the user sees `failure`'s words instead.
    public var reason: String {
        switch self {
        case .disallowedRedirect: "redirect"
        case .tooLarge: "response too large"
        case .timeout: "timeout"
        case .offline: "offline"
        case .tls: "TLS"
        case .other(let code): "URLError \(code)"
        }
    }

    /// What the user is told (DESIGN 11, No internals).
    public var failure: ReportFailure {
        switch self {
        case .disallowedRedirect, .tls: .insecure
        case .tooLarge: .response
        case .timeout, .offline, .other: .unreachable
        }
    }
}

/// Why a request failed, in the user's terms (DESIGN 11): every transport error and unexpected status maps to one
/// of these, each a localized `report.error.*` sentence; status codes and error classes go to the log only.
public enum ReportFailure: String, Equatable, Hashable, Sendable, Codable {
    /// No connection, the host not found or refusing, a timeout.
    case unreachable
    /// A TLS failure, or a redirect to a non-`https` URL.
    case insecure
    /// The service answered with a status the client cannot act on (`5xx`, `429`, an unexpected `3xx` …).
    case unavailable
    /// The response could not be read (too large).
    case response
    /// The device key could not be created or used on this computer.
    case key

    public var key: String { "report.error.\(rawValue)" }
}

/// The network seam of live reporting; tests use a scripted transport or the reference server.
public protocol ReportTransport: Sendable {
    /// Discovery `GET` (REPORTING 3.1): `Accept`, `User-Agent`, `If-None-Match`; up to three `https` redirects.
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError)
        -> ReportHTTPResponse
    /// An API request: never redirected (a `3xx` comes back as the response).
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError)
        -> ReportHTTPResponse
}

/// REPORTING 2.3 over URLSession: one ephemeral session per request, no cookies, credentials, cache or
/// authentication challenges (server trust only), the system proxy, TLS 1.2 or later, hard size caps and timeouts.
public struct URLSessionReportTransport: ReportTransport {
    public static let maxRedirects = 3

    let protocolClasses: [AnyClass]

    public init() {
        protocolClasses = []
    }

    init(protocolClasses: [AnyClass]) {
        self.protocolClasses = protocolClasses
    }

    public func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        var request = baseRequest(url: url, method: "GET", timeout: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return try await run(request, maxBytes: maxBytes, redirects: Self.maxRedirects, timeout: timeout)
    }

    public func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        var urlRequest = baseRequest(url: request.url, method: request.method, timeout: timeout)
        for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        return try await run(urlRequest, maxBytes: maxBytes, redirects: 0, timeout: timeout)
    }

    private func baseRequest(url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        // CFNetwork would add the user's languages; a constant says nothing about the user (REPORTING 1.3).
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func run(_ request: URLRequest, maxBytes: Int, redirects: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        let delegate = ReportSessionDelegate(maxBytes: maxBytes, redirects: redirects)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegate.queue)
        do {
            return try await delegate.run(request, session: session)
        } catch let error as ReportTransportError {
            throw error
        } catch {
            throw .other(-1)
        }
    }
}

/// Delegate of one request; all mutable state is touched only on its serial queue.
private final class ReportSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let queue: OperationQueue
    private let maxBytes: Int
    private var redirectsLeft: Int
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var failure: ReportTransportError?
    private var continuation: CheckedContinuation<ReportHTTPResponse, any Error>?

    init(maxBytes: Int, redirects: Int) {
        self.maxBytes = maxBytes
        redirectsLeft = redirects
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "io.github.zoefix.agentspeed.report"
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> ReportHTTPResponse {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard redirectsLeft > 0 else {
            // API requests: the 3xx itself is the answer, which the client treats as a failure.
            completionHandler(nil)
            return
        }
        guard newRequest.url?.scheme?.lowercased() == "https", newRequest.url?.user == nil else {
            failure = .disallowedRedirect
            completionHandler(nil)
            task.cancel()
            return
        }
        redirectsLeft -= 1
        var next = newRequest
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = .other(-1)
            completionHandler(.cancel)
            return
        }
        self.response = http
        if http.expectedContentLength > Int64(maxBytes) {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard buffer.count + data.count <= maxBytes else {
            failure = .tooLarge
            buffer = Data()
            dataTask.cancel()
            return
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()
        let result: Result<ReportHTTPResponse, any Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(Self.classify(error))
        } else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
            }
            result = .success(ReportHTTPResponse(status: response.statusCode, headers: headers, body: buffer,
                                                 finalURL: response.url))
        } else {
            result = .failure(ReportTransportError.other(-1))
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    /// The URL error class only: never a URL or anything else from the request.
    private static func classify(_ error: any Error) -> ReportTransportError {
        guard let error = error as? URLError else { return .other(-1) }
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tls
        default:
            return .other(error.code.rawValue)
        }
    }
}
