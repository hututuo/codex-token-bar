import AgentSpeedCore
import Foundation
import XCTest
@testable import CodexTokenBar

private actor SpeedReportTestTransport: ReportTransport {
    var gets = 0
    var sent: [ReportRequest] = []
    var held = false
    var alteredAPI = false
    func holdDiscovery() { held = true }
    func alterAPI() { alteredAPI = true }
    func requests() -> [ReportRequest] { sent }
    func count() -> Int { gets + sent.count }
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        gets += 1
        while held {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { throw .other(-999) }
        }
        let api = alteredAPI ? "https://other.example/api" : "https://speed-api.codexradar.com/api/agent-speed"
        return .init(status: 200, body: Data("""
        {"protocol":"agent-speed-report","versions":[1],"service":{"name":"test","terms":"https://deng.codexradar.com/agent-speed/terms/","privacy":"https://deng.codexradar.com/agent-speed/privacy/"},"api":"\(api)","apiKey":{"mode":"none"},"sections":["sources","models","cost","traffic"],"extensions":{"modelHarnessRequests":1,"executionModes":1,"profileAvatar":1,"sharedIdentity":1}}
        """.utf8))
    }
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        sent.append(request)
        if request.url.path.hasSuffix("/devices") {
            let value = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let reply: [String: Any] = ["status":"created","deviceId":value["deviceId"] ?? "", "username":value["username"] ?? ""]
            return .init(status: 201, body: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
        }
        return .init(status: 200, body: Data(#"{"status":"accepted"}"#.utf8))
    }
}

@MainActor
private final class SpeedReportTestMonitor: AgentSpeedReportingMonitor {
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class AgentSpeedReportingTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test.speed-report." + UUID().uuidString)! }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for local test transport")
    }

    func testDefaultOffAndInvitationNeverStartNetworkOrReaders() async throws {
        let prefs = defaults(), transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport,
            makeSigner: { _ in XCTFail("Must not create a key without opt-in"); return SoftwareReportSigner() },
            makeMonitor: { _ in monitor })
        controller.start(); controller.offerInvitation()
        XCTAssertTrue(controller.showingInvitation)
        XCTAssertFalse(controller.enabled)
        controller.dismissInvitation(); controller.offerInvitation()
        XCTAssertFalse(controller.showingInvitation)
        let restored = AgentSpeedReportingController(defaults: prefs, transport: transport, makeMonitor: { _ in monitor })
        restored.offerInvitation(); restored.start()
        XCTAssertFalse(restored.showingInvitation)
        XCTAssertEqual(monitor.starts, 0)
        let count = await transport.count()
        XCTAssertEqual(count, 0)
    }

    func testDisableWhileDiscoveringPreventsLateRegistrationAndScan() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.holdDiscovery()
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport,
            makeSigner: { _ in XCTFail("Cancelled setup cannot create identity"); return SoftwareReportSigner() },
            makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: "test-device")
        try await Task.sleep(for: .milliseconds(30))
        controller.setEnabled(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.phase, "off")
        XCTAssertEqual(monitor.starts, 0)
        let sent = await transport.requests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testDiscoveryCannotRedirectStatisticsToAnotherService() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.alterAPI()
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport,
            makeSigner: { _ in XCTFail("Unapproved destination cannot get device identity"); return SoftwareReportSigner() },
            makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: "test-device")
        try await waitFor { controller.phase == "error" }
        XCTAssertEqual(monitor.starts, 0)
        let sent = await transport.requests()
        XCTAssertTrue(sent.isEmpty)
        controller.setEnabled(false)
    }

    func testLiveWindowExcludesSeedHistoryAndPayloadContainsOnlyStatistics() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        var clock: Int64 = 0
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, monotonic: { clock }, makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: "test-device")
        try await waitFor { monitor.starts == 1 }
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .starting(progress: 0.8)
        snapshot.report.counters.add(.init(requests: 10, output: 1000, measuredOutput: 1000, measuredMs: 20_000, costMicroUsd: 99_000),
                                    to: .init(modelId: "gpt-6.1-sol", source: .codex))
        controller.receive(snapshot)
        snapshot.state = .running
        controller.receive(snapshot) // baseline: seed records cannot enter an outgoing delta
        for step in 1...10 {
            clock = Int64(step * 500)
            if step == 10 {
                snapshot.report.counters.add(.init(requests: 1, output: 250, input: 500, reasoning: 100,
                                                  measuredOutput: 250, measuredMs: 5000, costMicroUsd: 1234, unpricedRequests: 1),
                                            to: .init(modelId: "gpt-6.1-sol", source: .codex))
            }
            snapshot.live = .init(output: 50, total: 150)
            snapshot.liveEstimatedShare = 0.2
            controller.receive(snapshot)
        }
        try await waitFor { controller.lastReportAt != nil }
        let sent = await transport.requests()
        let reports = sent.filter { $0.url.path.hasSuffix("/reports") }
        XCTAssertEqual(reports.count, 1)
        let request = try XCTUnwrap(reports.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["schema","client","deviceId","username","run","sentAt","windowMs","activity","live","peak","delta","title","sources","models","cost"]))
        let delta = try XCTUnwrap(body["delta"] as? [String: Any])
        XCTAssertEqual(delta["requests"] as? Int, 1)
        XCTAssertEqual(delta["output"] as? Int, 250)
        XCTAssertEqual(delta["measuredMs"] as? Int, 5000)
        let cost = try XCTUnwrap(body["cost"] as? [String: Any])
        XCTAssertEqual(cost["deltaMicroUsd"] as? Int, 1234)
        XCTAssertEqual(cost["unpricedRequests"] as? Int, 1)
        XCTAssertEqual(cost["priceVersion"] as? Int, PriceBook.bundled.version)
        XCTAssertEqual(cost["knownShare"] as? Double, 0)
        let models = try XCTUnwrap(body["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["deltaMicroUsd"] as? Int, 1234)
        XCTAssertNil(body["traffic"])
        XCTAssertEqual((body["client"] as? [String: Any])?["app"] as? String, "CodexTokenBar")
        XCTAssertNotNil(request.header("X-AgentSpeed-Signature"))
        XCTAssertNil(request.header("Authorization"))
        controller.setEnabled(false)
        XCTAssertEqual(monitor.stops, 1)
        clock = 10_000; controller.receive(snapshot)
        let after = await transport.requests()
        XCTAssertEqual(after.count, sent.count)
    }

    func testFailedNicknameCannotGrantConsent() {
        let prefs = defaults()
        let controller = AgentSpeedReportingController(defaults: prefs)
        controller.setEnabled(true, username: "!")
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(prefs.bool(forKey: AgentSpeedReportingController.enabledKey))
    }

    func testProfileLinksArePinnedAndAllUpstreamHarnessesIncluded() {
        XCTAssertNil(AgentSpeedReportingController.safeProfile(URL(string: "https://evil.example/account")))
        XCTAssertNil(AgentSpeedReportingController.safeProfile(URL(string: "https://password@deng.codexradar.com/")))
        XCTAssertNotNil(AgentSpeedReportingController.safeProfile(URL(string: "https://deng.codexradar.com/u/test")))
        XCTAssertEqual(MonitorConfiguration().enabledSources.count, 13)
        XCTAssertEqual(Set(SourceKind.allCases.map(AgentSpeedReportingController.sourceName)).count, 13)
    }
}

/// Explicit opt-in live acceptance probe. Reuses this device's existing identity;
/// never seeds a new device, reads transcripts, or changes production preferences.
private actor SpeedReportAcceptanceTransport: ReportTransport {
    private let underlying = URLSessionReportTransport()
    private var outcomes: [[String: String]] = []
    func snapshot() -> [[String: String]] { outcomes }
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        try await underlying.get(url, etag: etag, userAgent: userAgent, maxBytes: maxBytes, timeout: timeout)
    }
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        let response = try await underlying.send(request, maxBytes: maxBytes, timeout: timeout)
        let parsed = ReportReply.parse(status: response.status, headers: response.headers, body: response.body)
        outcomes.append(["status": String(response.status), "code": parsed.code ?? "", "field": parsed.field ?? "", "reason": parsed.reason ?? ""])
        return response
    }
}

extension AgentSpeedReportingTests {
    func testExplicitLiveRegistrationDiagnostics() async throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_SPEED_LIVE_ACCEPTANCE_OUTPUT"] else {
            throw XCTSkip("Live service requests require explicit local acceptance opt-in")
        }
        let production = try XCTUnwrap(UserDefaults(suiteName: "local.codex.token-bar"))
        let device = try XCTUnwrap(production.string(forKey: AgentSpeedReportingController.deviceKey))
        let username = try XCTUnwrap(production.string(forKey: AgentSpeedReportingController.usernameKey))
        XCTAssertTrue(ReportCanonical.isDeviceId(device))
        let name = "test.speed-acceptance." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        prefs.set(device, forKey: AgentSpeedReportingController.deviceKey)
        let transport = SpeedReportAcceptanceTransport(), monitor = SpeedReportTestMonitor()
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport, makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: username)
        for _ in 0..<300 where controller.phase != "error" && monitor.starts == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = await transport.snapshot()
        let record: [String: Any] = ["responses": result, "phase": controller.phase, "message": controller.message,
                                    "readerStarts": monitor.starts, "sameDeviceRetry": true,
                                    "productionPreferencesChanged": false, "clientApp": "CodexTokenBar"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        controller.shutdown()
        XCTAssertFalse(result.isEmpty, "The explicit probe must reach the registered API")
    }
}
