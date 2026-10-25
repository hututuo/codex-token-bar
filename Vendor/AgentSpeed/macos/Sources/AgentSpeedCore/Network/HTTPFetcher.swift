import Foundation

/// One HTTPS `GET` of NETWORK 1: the request line and only these headers, against a feature's host list.
public struct HTTPFetchRequest: Equatable, Sendable {
    public var url: URL
    public var accept: String
    public var ifNoneMatch: String?
    public var userAgent: String
    public var maxBytes: Int
    /// Hosts the request and every redirect hop may use (HTTPS only).
    public var allowedHosts: Set<String>
    public var timeout: TimeInterval

    public init(
        url: URL,
        accept: String = "application/json",
        ifNoneMatch: String? = nil,
        userAgent: String,
        maxBytes: Int,
        allowedHosts: Set<String>,
        timeout: TimeInterval = HTTPFetchRequest.defaultTimeout
    ) {
        self.url = url
        self.accept = accept
        self.ifNoneMatch = ifNoneMatch
        self.userAgent = userAgent
        self.maxBytes = maxBytes
        self.allowedHosts = allowedHosts
        self.timeout = timeout
    }

    public static let defaultTimeout: TimeInterval = 15

    /// HTTPS on the allowed hosts, default port, no user information.
    public func permits(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), allowedHosts.contains(host),
              url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else { return false }
        return url.port.map { $0 == 443 } ?? true
    }
}

/// A response of any status; a `304` has an empty body. Bodies of other non-2xx statuses are not read.
public struct HTTPFetchResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var etag: String?
    public var finalURL: URL?

    public init(status: Int, body: Data = Data(), etag: String? = nil, finalURL: URL? = nil) {
        self.status = status
        self.body = body
        self.etag = etag
        self.finalURL = finalURL
    }
}

public enum HTTPFetchError: Error, Equatable, Sendable {
    /// Not HTTPS, or a host (or redirect hop) outside the feature's list.
    case disallowedURL
    /// Larger than the feature's cap, by `Content-Length` or while streaming.
    case tooLarge
    /// Timeouts, offline, TLS and other transport failures.
    case transport(String)

    /// A short reason for logs and the inline status, with nothing personal in it.
    public var reason: String {
        switch self {
        case .disallowedURL: "disallowed URL"
        case .tooLarge: "response too large"
        case .transport(let detail): detail
        }
    }
}

/// The network seam: the app uses `URLSessionTransport`, tests a scripted transport.
public protocol HTTPTransport: Sendable {
    func get(_ request: HTTPFetchRequest) async throws -> HTTPFetchResponse
}

/// NETWORK 1 transport: one ephemeral session per request with no cookies, credentials or cache (the app does its
/// own `ETag` handling), the system proxy, a 15 s timeout, every URL and redirect hop checked against the host list,
/// and a hard byte cap.
public struct URLSessionTransport: HTTPTransport {
    /// Tests insert a `URLProtocol` here; production leaves it empty.
    let protocolClasses: [AnyClass]

    public init() {
        protocolClasses = []
    }

    init(protocolClasses: [AnyClass]) {
        self.protocolClasses = protocolClasses
    }

    public func get(_ request: HTTPFetchRequest) async throws -> HTTPFetchResponse {
        guard request.permits(request.url) else { throw HTTPFetchError.disallowedURL }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        // CFNetwork adds Accept-Language from the user's languages; a constant says nothing about the user.
        urlRequest.setValue("*", forHTTPHeaderField: "Accept-Language")
        if let etag = request.ifNoneMatch { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let delegate = FetchDelegate(request: request)
        let session = URLSession(configuration: configuration(timeout: request.timeout), delegate: delegate, delegateQueue: delegate.queue)
        return try await delegate.run(urlRequest, session: session)
    }

    private func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        return config
    }
}

/// Delegate of one request; all mutable state is touched only on its serial queue.
private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let queue: OperationQueue
    private let request: HTTPFetchRequest
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var failure: HTTPFetchError?
    private var continuation: CheckedContinuation<HTTPFetchResponse, any Error>?

    init(request: HTTPFetchRequest) {
        self.request = request
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "io.github.zoefix.agentspeed.fetch"
    }

    func run(_ urlRequest: URLRequest, session: URLSession) async throws -> HTTPFetchResponse {
        let task = session.dataTask(with: urlRequest)
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
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.permits(newRequest.url) else {
            failure = .disallowedURL
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(newRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, request.permits(http.url) else {
            failure = .disallowedURL
            completionHandler(.cancel)
            return
        }
        self.response = http
        guard (200..<300).contains(http.statusCode) else {
            // Other statuses carry nothing the features use; the body is not read.
            completionHandler(.cancel)
            return
        }
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding").map { $0.lowercased() != "identity" } ?? false
        if !encoded, http.expectedContentLength > Int64(request.maxBytes) {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard buffer.count + data.count <= request.maxBytes else {
            failure = .tooLarge
            buffer = Data()
            dataTask.cancel()
            return
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()
        let result: Result<HTTPFetchResponse, any Error>
        if let failure {
            result = .failure(failure)
        } else if let response, !(200..<300).contains(response.statusCode) {
            result = .success(HTTPFetchResponse(status: response.statusCode, etag: Self.etag(response), finalURL: response.url))
        } else if let error {
            result = .failure(HTTPFetchError.transport(Self.describe(error)))
        } else if let response {
            result = .success(HTTPFetchResponse(status: response.statusCode, body: buffer, etag: Self.etag(response), finalURL: response.url))
        } else {
            result = .failure(HTTPFetchError.transport("no response"))
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func etag(_ response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag"), !value.isEmpty else { return nil }
        return value
    }

    /// The URL error code only: never a URL or anything else from the request.
    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError { return "URLError \(error.code.rawValue)" }
        return "transport error"
    }
}
