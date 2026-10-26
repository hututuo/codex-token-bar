import AgentSpeedCore
import CryptoKit
import Foundation
import Network

// Persisted independently of opt-in; capability publication never changes this choice.
enum AgentSpeedReportingMode: String, CaseIterable { case http, websocket }

struct SpeedSocketCounters {
    var built = 0, accepted = 0, duplicate = 0, rejected = 0, timedOut = 0, dropped = 0, unknown = 0
}
struct SpeedSocketPending {
    let hash: String
    let builtAt: Int64
    let observedAt: Int64?
    var sentAt: Int64?
}
/// Bounded ACK ledger contains hashes/times only. A socket generation never adopts another's ACKs.
struct SpeedSocketLedger {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let runID: String
    var pending: [Int: SpeedSocketPending] = [:]
    var counters = SpeedSocketCounters()
    mutating func reserve(seq: Int, body: Data, at now: Int64, limit: Int, observedAt: Int64? = nil) -> Bool {
        counters.built += 1
        guard pending.count < limit else { counters.dropped += 1; return false }
        pending[seq] = .init(hash: Self.hash(body), builtAt: now, observedAt: observedAt)
        return true
    }
    mutating func acknowledge(_ object: [String: JSONValue]) -> Bool {
        guard object["type"]?.string == "ack", let run = object["run"]?.object,
              run["id"]?.string == runID, let literal = run["seq"]?.literal, literal.isInteger,
              let seq = literal.int64, seq > 0, let pending = pending[Int(seq)], pending.sentAt != nil,
              object["bodySha256"]?.string == pending.hash,
              let status = object["status"]?.string, ["accepted", "duplicate"].contains(status),
              let received = object["receivedAt"]?.string, ReportWebSocketConfiguration.isTimestamp(received),
              let accepted = object["acceptedAt"]?.string, ReportWebSocketConfiguration.isTimestamp(accepted),
              let processing = object["processingMs"]?.literal, processing.isInteger,
              let ms = processing.int64, (0...900000).contains(ms) else { return false }
        self.pending[Int(seq)] = nil
        if status == "accepted" { counters.accepted += 1 } else { counters.duplicate += 1 }
        return true
    }
    mutating func discardAll() { counters.unknown += pending.count; pending.removeAll() }
}

private final class SpeedSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

@MainActor
final class AgentSpeedWebSocket {
    enum Failure: Error { case protocolError, configurationChanged, timedOut, stale, retry, terminal(String) }
    let config: ReportWebSocketConfiguration
    let runID: String
    private(set) var ledger: SpeedSocketLedger
    private(set) var ready = false
    var onReady: () -> Void = {}
    var onDisconnected: () -> Void = {}
    var onStatus: (String) -> Void = { _ in }
    var onAccepted: () -> Void = {}
    var onTerminal: (String) -> Void = { _ in }
    var onRecovery: (String, Int64?) -> Void = { _, _ in }
    var onConfigurationChanged: () -> Void = {}
    var onTransportUnavailable: (() -> Void)?
    private let api: ReportServiceURL
    private let makeRequest: @Sendable (String, URL, Data) async throws -> ReportRequest
    private var task: Task<Void, Never>?
    private var receiver: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectionID = UUID()
    private var watchdog: Task<Void, Never>?
    private var pingDeadline: Int64?
    private var nextPing: Int64 = 0
    private var retryAfter: Int64 = 0
    private var stopped = false
    private var suspended = false
    private var wakeRequested = false
    private var failures = 0
    private var ackStableSince: Int64?
    private var strikes = 0
    private var network: NWPathMonitor?
    private var lastPath: String?
    private var sendFailure: Error?
    static var tick: Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    init(api: ReportServiceURL, config: ReportWebSocketConfiguration, runID: String = ReportCanonical.newUUID(),
         makeRequest: @escaping @Sendable (String, URL, Data) async throws -> ReportRequest) {
        self.api = api; self.config = config; self.runID = runID
        self.ledger = .init(runID: runID); self.makeRequest = makeRequest
    }
    func start() {
        guard task == nil, !stopped else { return }
        let path = NWPathMonitor(); network = path
        path.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted())"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let old = lastPath, old != signature { wakeRequested = true; disconnect() }
                lastPath = signature
            }
        }
        path.start(queue: DispatchQueue(label: "tokenbar.report.network", qos: .utility))
        task = Task { [weak self] in await self?.loop() }
    }
    func stop() {
        stopped = true; task?.cancel(); task = nil; network?.cancel(); network = nil
        disconnect()
        onReady = {}; onDisconnected = {}; onAccepted = {}; onTransportUnavailable = nil
    }
    func suspend() { suspended = true; disconnect(); onStatus("已暂停 · 等待唤醒") }
    func pauseUntilActivity() { suspended = true; disconnect(); onStatus("暂时无活动 · 等待新数据") }
    func resume() { suspended = false; wakeRequested = true }
    func disconnect() {
        connectionID = UUID(); ready = false; watchdog?.cancel(); watchdog = nil
        receiver?.cancel(); receiver = nil; session?.invalidateAndCancel(); session = nil
        pingDeadline = nil; ledger.discardAll(); ackStableSince = nil; onDisconnected()
    }
    private func loop() async {
        while !stopped && !Task.isCancelled {
            if suspended { try? await Task.sleep(for: .milliseconds(250)); continue }
            do { try await connect() }
            catch Failure.configurationChanged {
                disconnect(); onConfigurationChanged(); return
            }
            catch Failure.protocolError { disconnect(); onTerminal("WebSocket 协议不兼容，请手动重试"); return }
            catch Failure.terminal(let text) { disconnect(); onTerminal(text); return }
            catch {
                let transportError = sendFailure ?? error
                sendFailure = nil
                let code = receiver?.closeCode.rawValue ?? 0
                let status = (receiver?.response as? HTTPURLResponse)?.statusCode ?? 0
                let retryHeader = (receiver?.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let retry = retryHeader.flatMap { value -> Int? in
                    if let seconds = Int(value) { return seconds }
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    return formatter.date(from: value).map { Int(ceil($0.timeIntervalSinceNow)) }
                }
                disconnect()
                if stopped || Task.isCancelled { return }
                if code == 4410 || status == 410 { onRecovery("gone", nil); return }
                if code == 1009 { onConfigurationChanged(); return }
                if [1002,1003,1007,4000,4001,4003,4004,4009,4410].contains(code) || [401,403,404,410,422].contains(status) {
                    onTerminal(code == 4009 ? "设备已在另一处连接，请确认没有重复上报" : "服务拒绝连接，请手动重试或检查设置"); return
                }
                if [4429,4503].contains(code) || [429,503].contains(status) || retryHeader != nil {
                    retryAfter = max(retryAfter, Self.tick + Int64(min(max(retry ?? 60, 5), 3600)) * 1000)
                }
                if let fallback = onTransportUnavailable,
                   Self.canFallBack(error: transportError, closeCode: code, httpStatus: status,
                                    suspended: suspended, rateLimited: Self.tick < retryAfter) {
                    fallback(); return
                }
            }
            if stopped || Task.isCancelled { return }
            onStatus("WebSocket 重新连接中 · 未确认数据已丢弃")
            let base = min(30000.0, 500 * pow(2, Double(min(failures, 6))))
            let delay = max(Int64(base * Double.random(in: 0.8...1.2)), retryAfter - Self.tick)
            failures = min(30, failures + 1)
            let deadline = Self.tick + max(0, delay)
            while Self.tick < deadline && !stopped && !Task.isCancelled {
                if wakeRequested && Self.tick >= retryAfter { wakeRequested = false; break }
                try? await Task.sleep(for: .milliseconds(min(250, max(1, deadline - Self.tick))))
            }
        }
    }
    /// A transport failure may change channel; service rejection and backoff may not.
    static func canFallBack(error: Error, closeCode: Int, httpStatus: Int,
                            suspended: Bool, rateLimited: Bool) -> Bool {
        guard !suspended, !rateLimited,
              ![1000,1002,1003,1007,1008,1009,1013,4000,4001,4003,4004,4009,4410,4429,4503].contains(closeCode),
              (!(300...499).contains(httpStatus) || httpStatus == 408), httpStatus != 503 else { return false }
        if [408,502,504].contains(httpStatus) { return true }
        if let failure = error as? Failure {
            switch failure {
            case .timedOut: return true
            case .stale, .retry, .protocolError, .configurationChanged, .terminal: return false
            }
        }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .cancelled].contains(URLError.Code(rawValue: value.code))
    }
    private func connect() async throws {
        onStatus("正在连接 WebSocket…")
        let https = api.appending(endpoint: "/v1/reports/ws")
        let signed = try await makeRequest("GET", https, Data())
        guard !stopped, !suspended, !Task.isCancelled else { throw Failure.retry }
        var parts = URLComponents(url: https, resolvingAgainstBaseURL: false)!
        parts.scheme = https.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        for h in signed.headers { request.setValue(h.value, forHTTPHeaderField: h.name) }
        request.setValue(ReportWebSocketConfiguration.subprotocolName, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false; cfg.urlCredentialStorage = nil; cfg.urlCache = nil
        cfg.waitsForConnectivity = false; cfg.timeoutIntervalForRequest = 10; cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: cfg, delegate: SpeedSocketDelegate(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = config.maxMessageBytes
        receiver = socket; connectionID = UUID(); let id = connectionID
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, id == self.connectionID, !self.ready { socket.cancel() }
        }
        defer { timeout.cancel() }
        socket.resume()
        let first = try await socket.receive()
        guard id == connectionID, !stopped, !suspended else { throw Failure.retry }
        guard let response = socket.response as? HTTPURLResponse,
              response.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == ReportWebSocketConfiguration.subprotocolName,
              (response.value(forHTTPHeaderField: "Sec-WebSocket-Extensions") ?? "").isEmpty else { throw Failure.protocolError }
        guard case .string(let text) = first, let object = try JSONParser.parse(Data(text.utf8), maxDepth: 32, rejectDuplicateKeys: true).object else { throw Failure.protocolError }
        guard config.matchesReady(object) else { throw Failure.configurationChanged }
        timeout.cancel(); ready = true; nextPing = Self.tick + Int64(config.pingIntervalSeconds) * 1000
        onReady(); onStatus(config.minIntervalMs > 50 ? "WebSocket 已连接 · 服务节流" : "WebSocket 已连接 · 等待有效上报")
        watchdog = Task { @MainActor [weak self] in
            while let self, self.ready, id == self.connectionID, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, id == self.connectionID else { return }
                let now = Self.tick
                if self.ledger.pending.values.contains(where: { item in item.sentAt.map { now - $0 >= Int64(self.config.ackTimeoutMs) } ?? (now - min(item.builtAt, item.observedAt ?? item.builtAt) > 1000) }) {
                    self.ledger.counters.timedOut += 1; socket.cancel(); return
                }
                if let deadline = self.pingDeadline, now >= deadline { socket.cancel(); return }
                if now >= self.nextPing, self.pingDeadline == nil {
                    self.pingDeadline = now + Int64(self.config.pongTimeoutSeconds) * 1000
                    self.nextPing = now + Int64(self.config.pingIntervalSeconds) * 1000
                    socket.sendPing { [weak self] error in
                        let ok = error == nil
                        Task { @MainActor [weak self] in
                            guard let self, id == self.connectionID else { return }
                            if ok { self.pingDeadline = nil } else { socket.cancel() }
                        }
                    }
                }
            }
        }
        while id == connectionID && !stopped {
            let message = try await socket.receive()
            guard id == connectionID else { throw Failure.retry }
            guard case .string(let text) = message, text.utf8.count <= config.maxMessageBytes,
                  let object = try JSONParser.parse(Data(text.utf8), maxDepth: 32, rejectDuplicateKeys: true).object else { throw Failure.protocolError }
            if object["type"]?.string == "ack" {
                if ledger.acknowledge(object) {
                    let now = Self.tick
                    if ackStableSince == nil { ackStableSince = now }
                    if now - (ackStableSince ?? now) >= 60000 { failures = 0 }
                    strikes = 0
                    onAccepted()
                }
            } else if object["type"]?.string == "error" {
                let code = object["error"]?.object?["code"]?.string ?? "unknown"
                if let run = object["run"]?.object, run["id"]?.string == runID, let seq = run["seq"]?.literal?.int64,
                   ledger.pending.removeValue(forKey: Int(seq)) != nil { ledger.counters.rejected += 1 }
                if ["rate_limited", "temporarily_unavailable"].contains(code) || [429,503].contains(Int(object["httpStatus"]?.literal?.int64 ?? 0)) {
                    let wait = object["error"]?.object?["retryAfterSeconds"]?.literal?.int64 ?? 60
                    retryAfter = max(retryAfter, Self.tick + min(max(wait, 5), 3600) * 1000); throw Failure.retry
                }
                if code == "gone" { onRecovery(code, nil); return }
                if (500...599).contains(Int(object["httpStatus"]?.literal?.int64 ?? 0)) { throw Failure.retry }
                if code == "timestamp_out_of_window" {
                    let time = object["error"]?.object?["serverTime"]?.literal?.int64
                    onRecovery(code, time); continue
                }
                if ["seq_conflict","run_conflict","unknown_device","version_unsupported","payload_too_large"].contains(code) {
                    onRecovery(code, nil); return
                }
                strikes += 1
                if ["signature_invalid","forbidden","api_key_invalid","api_key_required","unknown_device","username_mismatch","gone","run_conflict","seq_conflict"].contains(code) || object["fatal"]?.bool == true || strikes >= 3 {
                    throw Failure.terminal("服务拒绝上报，请确认昵称、设备和协议后手动重试")
                }
            } else { throw Failure.protocolError }
        }
    }
    /// No application queue. A built window consumes its sequence even if it is dropped here.
    func dropBuiltWindow() { ledger.counters.built += 1; ledger.counters.dropped += 1 }
    func submit(body: Data, seq: Int, observedAt: Int64? = nil) {
        guard ready, let socket = receiver else { ledger.counters.dropped += 1; return }
        let id = connectionID, now = Self.tick
        guard ledger.reserve(seq: seq, body: body, at: now, limit: config.maxInFlight, observedAt: observedAt) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let signed = try await makeRequest("POST", api.appending(endpoint: ReportEndpoint.reports), body)
                guard ready, id == connectionID, Self.tick - min(now, observedAt ?? now) <= 1000 else { ledger.pending[seq] = nil; ledger.counters.dropped += 1; return }
                let headers = signed.headers.filter { [ReportCanonical.deviceHeader,ReportCanonical.timestampHeader,ReportCanonical.nonceHeader,ReportCanonical.signatureHeader].contains($0.name) }
                let outer = ReportJSON.object(["type": .string("report"), "headers": .object(headers.map { .init($0.name,.string($0.value)) }), "body": .string(String(decoding: body, as: UTF8.self))]).compactData
                guard body.count <= 16384, outer.count <= config.maxMessageBytes else { ledger.pending[seq] = nil; ledger.counters.dropped += 1; return }
                ledger.pending[seq]?.sentAt = Self.tick
                try await socket.send(.string(String(decoding: outer, as: UTF8.self)))
            } catch {
                if id == connectionID { sendFailure = error; socket.cancel() }
            }
        }
    }
}
