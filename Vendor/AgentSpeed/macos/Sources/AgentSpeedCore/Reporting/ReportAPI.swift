import Foundation
import os

/// The endpoints of REPORTING 2.4 for one service, over a transport. Every call returns a validated reply or a
/// transport error; nothing here retries (the scheduler and the controller decide).
public struct ReportAPI: Sendable {
    public static let discoveryTimeout: TimeInterval = 15
    public static let apiTimeout: TimeInterval = 10
    public static let apiMaxBytes = 16_384

    public enum DiscoveryOutcome: Equatable, Sendable {
        case document(ReportDiscovery, etag: String?)
        case notModified
        /// The URL does not offer this API: `404`, another `4xx` except `410` and `429`, or a response that is not an
        /// `agent-speed-report` document — not a JSON object, over 64 KiB (typically a web page), another `protocol`.
        case notSupported
        /// An `agent-speed-report` document that breaks REPORTING 3.2.
        case invalid
        /// `410`: the service stopped for good (REPORTING 8.3).
        case gone
        /// Anything else: try again later (DESIGN 11 maps each to a sentence; the details are logged).
        case failed(ReportFailure)
    }

    public var transport: any ReportTransport
    public var userAgent: String

    public init(transport: any ReportTransport = URLSessionReportTransport(), userAgent: String) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func discover(_ service: ReportServiceURL, etag: String? = nil) async -> DiscoveryOutcome {
        let response: ReportHTTPResponse
        do {
            response = try await transport.get(service.discoveryURL, etag: etag, userAgent: userAgent,
                                               maxBytes: ReportDiscovery.maxBytes, timeout: Self.discoveryTimeout)
        } catch {
            ReportLog.network.info("discovery \(service.host, privacy: .public) failed: \(error.reason, privacy: .public)")
            // A body over 64 KiB is not a discovery document (REPORTING 3.2): usually the site's web page.
            return error == .tooLarge ? .notSupported : .failed(error.failure)
        }
        ReportLog.network.info(
            "GET \(service.host, privacy: .public) discovery -> \(response.status) \(response.body.count) bytes")
        return Self.discoveryOutcome(status: response.status, body: response.body, etag: etag,
                                     responseETag: response.headers["etag"], service: service)
    }

    /// REPORTING 3.1 and 3.2 for one response; DESIGN 11 shows each outcome as one localized sentence.
    static func discoveryOutcome(status: Int, body: Data, etag: String?, responseETag: String?,
                                 service: ReportServiceURL) -> DiscoveryOutcome {
        switch status {
        case 200:
            switch ReportDiscovery.parse(body, service: service) {
            case .success(let document):
                return .document(document, etag: responseETag)
            case .failure(let problem):
                ReportLog.network.info("discovery invalid: \(String(describing: problem), privacy: .public)")
                return problem.isOtherDocument ? .notSupported : .invalid
            }
        case 304: return etag == nil ? .failed(.unavailable) : .notModified
        case 410: return .gone
        case 429: return .failed(.unavailable)
        case 400..<500: return .notSupported
        default: return .failed(.unavailable)
        }
    }

    /// Sends one signed request and parses the answer (16 KiB cap, 10 s timeout).
    public func call(_ request: ReportRequest) async -> Result<ReportReply, ReportTransportError> {
        let started = Date()
        do {
            let response = try await transport.send(request, maxBytes: Self.apiMaxBytes, timeout: Self.apiTimeout)
            let reply = ReportReply.parse(status: response.status, headers: response.headers, body: response.body)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            ReportLog.network.info("""
                \(request.method, privacy: .public) \(ReportURLs.authority(of: request.url), privacy: .public)\
                \(ReportURLs.requestPath(of: request.url), privacy: .public) -> \(response.status) \
                \(reply.code ?? "", privacy: .public) sent \(request.body.count) received \(response.body.count) \
                \(millis) ms \(reply.logMessage ?? "", privacy: .public)
                """)
            return .success(reply)
        } catch {
            ReportLog.network.info("""
                \(request.method, privacy: .public) \(ReportURLs.authority(of: request.url), privacy: .public)\
                \(ReportURLs.requestPath(of: request.url), privacy: .public) failed: \(error.reason, privacy: .public)
                """)
            return .failure(error)
        }
    }
}

/// The bodies the client writes besides reports (REPORTING 4).
public enum ReportDocuments {
    public static func registration(deviceId: String, username: String, publicKey: ReportPublicKey,
                                    client: ReportClientInfo, transfer: Bool = false) -> Data {
        var members: [ReportJSON.Member] = [
            .init("schema", .int(1)), .init("deviceId", .string(deviceId)), .init("username", .string(username)),
            .init("publicKey", publicKey.jwk), .init("client", client.json),
        ]
        if transfer { members.append(.init("transfer", .bool(true))) }
        return ReportJSON.object(members).compactData
    }

    public static func rename(username: String) -> Data {
        ReportJSON.object(["username": .string(username)]).compactData
    }

    public static func rotation(publicKey: ReportPublicKey) -> Data {
        ReportJSON.object(["publicKey": publicKey.jwk]).compactData
    }
}

/// Endpoint paths under `api` (REPORTING 2.4).
public enum ReportEndpoint {
    public static let devices = "/v1/devices"
    public static let reports = "/v1/reports"

    public static func device(_ id: String) -> String { "/v1/devices/\(id)" }
    public static func key(_ id: String) -> String { "/v1/devices/\(id)/key" }
}

/// Request logging (REPORTING 2.3): method, host, path, status, error code, sizes and timing — never bodies,
/// signatures or API keys.
public enum ReportLog {
    public static let network = Logger(subsystem: "io.github.zoefix.agentspeed", category: "report")
}
