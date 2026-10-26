import AgentSpeedCore
import XCTest
@testable import CodexTokenBar

@MainActor
final class AgentSpeedWebSocketTests: XCTestCase {
    private var raw: String { #"{"extensions":{"reportWebSocket":1},"websocket":{"path":"/v1/reports/ws","subprotocol":"agent-speed-report.v1"}}"# }
    private func config(_ text: String? = nil) throws -> ReportWebSocketConfiguration {
        try XCTUnwrap(ReportWebSocketConfiguration(root: try XCTUnwrap(JSONParser.parse(text ?? raw).object)))
    }
    func testStrictCapabilityAndInvalidLimitsDoNotEnableWebSocket() throws {
        XCTAssertEqual(try config().maxInFlight, 8)
        for value in ["true", "\"1\"", "1.0", "null", "2"] {
            let root = try XCTUnwrap(JSONParser.parse(raw.replacingOccurrences(of: "reportWebSocket\":1", with: "reportWebSocket\":" + value)).object)
            XCTAssertNil(ReportWebSocketConfiguration(root: root))
        }
        for extra in ["\"minIntervalMs\":9", "\"maxInFlight\":65", "\"ackTimeoutMs\":500.0", "\"pongTimeoutSeconds\":20"] {
            let text = raw.replacingOccurrences(of: "\"path\":", with: extra + ",\"path\":")
            XCTAssertNil(ReportWebSocketConfiguration(root: try XCTUnwrap(JSONParser.parse(text).object)))
        }
    }
    func testReadyMustExactlyMatchNegotiatedConfiguration() throws {
        let c = try config()
        let text = #"{"type":"ready","protocol":"agent-speed-report","version":1,"transportVersion":1,"serverTime":"2026-10-25T10:00:00.000Z","minIntervalMs":50,"maxInFlight":8,"ackTimeoutMs":2000,"maxMessageBytes":65536,"pingIntervalSeconds":20,"pongTimeoutSeconds":10}"#
        XCTAssertTrue(c.matchesReady(try XCTUnwrap(JSONParser.parse(text).object)))
        XCTAssertFalse(c.matchesReady(try XCTUnwrap(JSONParser.parse(text.replacingOccurrences(of: "\"maxInFlight\":8", with: "\"maxInFlight\":9")).object)))
        XCTAssertThrowsError(try JSONParser.parse(#"{"type":"ack","type":"ready"}"#, rejectDuplicateKeys: true))
        XCTAssertNoThrow(try JSONParser.parse(#"{"type":"ack","type":"ready"}"#)) // Legacy reader unchanged.
    }
    func testACKRequiresRunSequenceHashAndIsConsumedOnce() throws {
        let run = ReportCanonical.newUUID(), body = Data("{}".utf8)
        var ledger = SpeedSocketLedger(runID: run)
        XCTAssertTrue(ledger.reserve(seq: 1, body: body, at: 0, limit: 8)); ledger.pending[1]?.sentAt = 1
        let ack = #"{"type":"ack","run":{"id":"RUN","seq":1},"status":"accepted","bodySha256":"HASH","receivedAt":"2026-10-25T10:00:00.000Z","acceptedAt":"2026-10-25T10:00:00.001Z","processingMs":1}"#
            .replacingOccurrences(of: "RUN", with: run).replacingOccurrences(of: "HASH", with: SpeedSocketLedger.hash(body))
        for wrong in [ack.replacingOccurrences(of: run, with: ReportCanonical.newUUID()), ack.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":2"), ack.replacingOccurrences(of: SpeedSocketLedger.hash(body), with: String(repeating: "0", count: 64)), ack.replacingOccurrences(of: "accepted\"", with: "queued\"")] {
            XCTAssertFalse(ledger.acknowledge(try XCTUnwrap(JSONParser.parse(wrong).object)))
            XCTAssertEqual(ledger.pending.count, 1)
        }
        XCTAssertTrue(ledger.acknowledge(try XCTUnwrap(JSONParser.parse(ack).object)))
        XCTAssertFalse(ledger.acknowledge(try XCTUnwrap(JSONParser.parse(ack).object)))
        XCTAssertEqual(ledger.counters.accepted, 1)
    }
    func testBackpressureAndDisconnectDropRatherThanQueueOrReplay() {
        var ledger = SpeedSocketLedger(runID: ReportCanonical.newUUID())
        XCTAssertTrue(ledger.reserve(seq: 1, body: Data(), at: 0, limit: 1))
        XCTAssertFalse(ledger.reserve(seq: 2, body: Data(), at: 0, limit: 1))
        XCTAssertEqual(ledger.pending.count, 1); XCTAssertEqual(ledger.counters.dropped, 1)
        ledger.discardAll(); XCTAssertTrue(ledger.pending.isEmpty); XCTAssertEqual(ledger.counters.unknown, 1)
        XCTAssertTrue(ledger.reserve(seq: 3, body: Data(), at: 10, limit: 1))
        XCTAssertNil(ledger.pending[1]); XCTAssertNil(ledger.pending[2])
    }
    func testDefaultAndInvalidPersistedTransportRemainHTTPWithoutConsent() {
        let suite = "test.speed-ws-choice." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentSpeedReportingController(defaults: prefs).transport, .http)
        prefs.set("future", forKey: AgentSpeedReportingController.transportKey)
        let controller = AgentSpeedReportingController(defaults: prefs)
        XCTAssertEqual(controller.transport, .http)
        controller.setTransport(.websocket)
        XCTAssertFalse(controller.enabled); XCTAssertEqual(prefs.string(forKey: AgentSpeedReportingController.transportKey), "websocket")
        XCTAssertEqual(AgentSpeedReportingController(defaults: prefs).transport, .websocket)
        controller.shutdown()
    }

    func testOnlyTransientTransportFailurePermitsHTTPFallback() {
        for code in [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(AgentSpeedWebSocket.canFallBack(error: URLError(code), closeCode: 0, httpStatus: 0, suspended: false, rateLimited: false))
        }
        for code in [URLError.secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected] {
            XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: URLError(code), closeCode: 0, httpStatus: 0, suspended: false, rateLimited: false))
        }
        for status in [301,401,403,404,410,422,429,503] {
            XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: URLError(.networkConnectionLost), closeCode: 0, httpStatus: status, suspended: false, rateLimited: false))
        }
        for code in [1000,1002,1003,1007,1008,1009,1013,4000,4001,4003,4004,4009,4410,4429,4503] {
            XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: URLError(.networkConnectionLost), closeCode: code, httpStatus: 0, suspended: false, rateLimited: false))
        }
        XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: URLError(.cancelled), closeCode: 0, httpStatus: 0, suspended: true, rateLimited: false))
        XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: AgentSpeedWebSocket.Failure.retry, closeCode: 0, httpStatus: 0, suspended: false, rateLimited: true))
        XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: AgentSpeedWebSocket.Failure.retry, closeCode: 0, httpStatus: 101, suspended: false, rateLimited: false)) // explicit server retry is not a network break
        XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: AgentSpeedWebSocket.Failure.protocolError, closeCode: 0, httpStatus: 0, suspended: false, rateLimited: false))
        XCTAssertTrue(AgentSpeedWebSocket.canFallBack(error: URLError(.badServerResponse), closeCode: 0, httpStatus: 502, suspended: false, rateLimited: false))
        XCTAssertFalse(AgentSpeedWebSocket.canFallBack(error: URLError(.badServerResponse), closeCode: 0, httpStatus: 502, suspended: false, rateLimited: true))
    }

    /// Actual native signing and URLSession transport; isolated service + new device key + synthetic metrics only.
    func testExplicitTestServiceRegistrationAndWebSocketACK() async throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_SPEED_WS_LIVE_OUTPUT"] else {
            throw XCTSkip("Explicit opt-in required for test service traffic")
        }
        let serviceText = ProcessInfo.processInfo.environment["CODEX_SPEED_WS_SERVICE"] ?? "https://speed-test.codexradar.com"
        guard ["https://speed-test.codexradar.com", "https://deng.codexradar.com"].contains(serviceText) else { return XCTFail("Unapproved service") }
        let production = serviceText == "https://deng.codexradar.com"
        let service = try ReportServiceURL.parse(serviceText).get()
        let api = ReportAPI(transport: URLSessionReportTransport(), userAgent: "CodexTokenBar/0.9.7")
        guard case .document(let document, _) = await api.discover(service) else { return XCTFail("Test discovery failed") }
        XCTAssertEqual(document.api.string, production ? AgentSpeedReportingController.apiURL : "https://speed-test.codexradar.com/api/agent-speed")
        let c = try XCTUnwrap(document.websocket)
        let id = ReportCanonical.newUUID(), username = "TokenBar-Mac-WS-" + UUID().uuidString.prefix(6)
        let signer = try AgentSpeedReportingIdentity.signer(deviceID: id)
        let builder = ReportRequestBuilder(userAgent: "CodexTokenBar/0.9.7", deviceId: id, apiKey: nil)
        let reg = ReportDocuments.registration(deviceId: id, username: username, publicKey: signer.publicKey, client: AgentSpeedReportingController.client)
        let request = try builder.make(method: "POST", url: document.api.appending(endpoint: ReportEndpoint.devices), body: reg, signer: signer, timestamp: AgentSpeedReportingController.nowMS / 1000)
        let reply = await api.call(request)
        guard case .success(let registered) = reply, registered.isSuccess else { return XCTFail("Test registration rejected: \(String(describing: reply))") }
        let socket = AgentSpeedWebSocket(api: document.api, config: c) { method, url, body in
            try builder.make(method: method, url: url, body: body, signer: signer, timestamp: Int64(Date().timeIntervalSince1970))
        }
        var accepted = false, status = "", terminal = "", sent: Int64 = 0, ackMS: Int64 = 0
        var ackCount = 0, readyCount = 0, seq = 0
        var latencies: [Int64] = []
        socket.onStatus = { status = $0 }; socket.onTerminal = { terminal = $0 }
        socket.onAccepted = { accepted = true; ackCount += 1; ackMS = AgentSpeedWebSocket.tick - sent; latencies.append(ackMS) }
        let sendProbe = {
            seq += 1
            var window = ReportWindow(ReportSample())
            let key = ReportModelKey(modelId: "gpt-6.1-sol", source: .codex)
            let synthetic = ReportSample(live: Rate(output: 100, total: 100), facts: ReportLiveFacts(
                agents: [.codex: .init(generating: 1, active: 1)], counters: .init(byModel: [key: .init(requests: 1, output: 5, measuredOutput: 5, measuredMs: 50)])))
            let sample = production ? ReportSample() : synthetic
            let envelope = ReportEnvelope(client: AgentSpeedReportingController.client, deviceId: id, username: username, runId: socket.runID,
                seq: seq, sentAtMs: AgentSpeedReportingController.nowMS, windowMs: 50, activity: .active, titleLevel: 0)
            let fitted = ReportBody.fitted(envelope, window.take(sample), sample, .init(sections: []))
            guard case .object(var fields) = fitted.json else { return }
            fields.append(.init("realtime", .object(["sourceMode": .string("unknown"), "observedAt": .null, "observationAgeMs": .null, "sourceResolutionMs": .null])))
            sent = AgentSpeedWebSocket.tick
            socket.submit(body: ReportJSON.object(fields).compactData, seq: seq)
        }
        socket.onReady = { readyCount += 1; sendProbe() }
        socket.start()
        for _ in 0..<300 where !accepted && terminal.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        var reconnected = false, heartbeatAlive = false
        if accepted {
            socket.suspend()
            XCTAssertTrue(socket.ledger.pending.isEmpty)
            try await Task.sleep(for: .milliseconds(300))
            socket.resume()
            for _ in 0..<300 where ackCount < 2 && terminal.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            reconnected = readyCount >= 2 && ackCount >= 2
            if reconnected {
                try await Task.sleep(for: .seconds(22)) // Real native Ping/Pong interval, no OS/network changes.
                if socket.ready { sendProbe() }
                for _ in 0..<100 where ackCount < 3 && terminal.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                heartbeatAlive = ackCount >= 3
            }
        }
        let record: [String: Any] = ["service":production ? "production" : "test", "platform":"macOS", "clientApp":"CodexTokenBar", "username":username,
            "registration":true, "ready":socket.ready, "accepted":accepted,"status":status,"terminal":terminal,"buildToACKMs":ackMS,
            "syntheticMetrics":!production,"zeroUsageProtocolProbe":production,"ACKCount":ackCount,"readyConnections":readyCount,"reconnectSameRun":reconnected,"heartbeatConnectionAliveAfter22s":heartbeatAlive,"buildToACKMsSamples":latencies,"physicalSleepTested":false,"physicalNetworkSwitchTested":false,"systemDeviceKey":true,"productionKeyReused":false,"published":false]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
        socket.stop()
        let cleanup = try builder.make(method: "DELETE", url: document.api.appending(endpoint: ReportEndpoint.device(id)), body: Data(), signer: signer, timestamp: Int64(Date().timeIntervalSince1970))
        _ = await api.call(cleanup) // Only the new zero-usage probe device, never a user/production identity.
        XCTAssertTrue(reconnected, "Same run must reconnect after client suspension")
        XCTAssertTrue(heartbeatAlive, "Connection must survive real Ping/Pong interval")
        XCTAssertTrue(accepted, terminal.isEmpty ? status : terminal)
    }
}

private actor SocketHTTPTrace: ReportTransport {
    let base = URLSessionReportTransport()
    var reportPosts = 0
    func count() -> Int { reportPosts }
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError) -> ReportHTTPResponse {
        try await base.get(url, etag: etag, userAgent: userAgent, maxBytes: maxBytes, timeout: timeout)
    }
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError) -> ReportHTTPResponse {
        if request.url.path.hasSuffix("/v1/reports") { reportPosts += 1 }
        return try await base.send(request, maxBytes: maxBytes, timeout: timeout)
    }
}
@MainActor
private final class SocketNoReader: AgentSpeedReportingMonitor {
    var starts = 0
    func start() { starts += 1 }
    func stop() {}
}
extension AgentSpeedWebSocketTests {
    func testExplicitProductionControllerUsesOnlySelectedSocketForReports() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEX_SPEED_WS_CONTROLLER_OUTPUT"] else { throw XCTSkip("Explicit opt-in required") }
        let suite = "test.speed-ws-controller." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(ReportCanonical.newUUID(), forKey: AgentSpeedReportingController.deviceKey)
        let key = SoftwareReportSigner(), trace = SocketHTTPTrace(), monitor = SocketNoReader()
        let controller = AgentSpeedReportingController(defaults: prefs, transport: trace, makeSigner: { _ in key }, makeRealtimeMonitor: { _ in monitor }, makeMonitor: { _ in monitor })
        controller.setTransport(.websocket)
        controller.setEnabled(true, username: "TokenBar-Ctrl-" + UUID().uuidString.prefix(6))
        for _ in 0..<300 where controller.phase != "connected" && controller.phase != "error" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(controller.phase, "connected", controller.message)
        XCTAssertNil(controller.lastReportAt, "Ready alone must not be displayed as successful reporting")
        var frame = SpeedSnapshot.empty; frame.state = .running
        controller.receive(frame)
        frame.report.agents[.codex] = ReportAgentCounts() // Changed zero-valued availability sample; no invented usage.
        controller.receive(frame)
        for _ in 0..<100 where controller.lastReportAt == nil && controller.phase != "error" { try await Task.sleep(for: .milliseconds(100)) }
        let posts = await trace.count()
        let result: [String: Any] = ["phase":controller.phase,"validACK":controller.lastReportAt != nil,"HTTPReportPosts":posts,
            "monitorStarts":monitor.starts,"zeroUsage":true,"productionPreferencesChanged":false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
        XCTAssertNotNil(controller.lastReportAt, controller.message); XCTAssertEqual(posts, 0)
        controller.shutdown()
        if let id = prefs.string(forKey: AgentSpeedReportingController.deviceKey) {
            let api = ReportAPI(transport: URLSessionReportTransport(), userAgent: AgentSpeedReportingController.userAgent)
            let service = try ReportServiceURL.parse(AgentSpeedReportingController.apiURL).get()
            let request = try ReportRequestBuilder(userAgent: AgentSpeedReportingController.userAgent, deviceId: id, apiKey: nil)
                .make(method: "DELETE", url: service.appending(endpoint: ReportEndpoint.device(id)), body: Data(), signer: key, timestamp: AgentSpeedReportingController.nowMS / 1000)
            _ = await api.call(request)
        }
    }
}
