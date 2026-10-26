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
        snapshot.sources = [
            .init(kind: .codex, enabled: true, rootPath: "", available: true, sessionCount: 1,
                  live: .init(output: 50, total: 150), today: .zero, activeAgents: 0),
        ]
        snapshot.live = .init(output: 50, total: 150)
        snapshot.report.counters.add(.init(requests: 10, output: 1000, measuredOutput: 1000, measuredMs: 20_000),
                                    to: .init(modelId: "gpt-6.1-sol", source: .codex))
        controller.receive(snapshot)
        snapshot.state = .running
        controller.receive(snapshot) // baseline: seed records cannot enter an outgoing delta
        for step in 1...10 {
            clock = Int64(step * 500)
            if step == 10 {
                snapshot.report.counters.add(.init(requests: 1, output: 250, input: 500, reasoning: 100,
                                                  measuredOutput: 250, measuredMs: 5000),
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
        XCTAssertEqual(Set(body.keys), Set(["schema","client","deviceId","username","run","sentAt","windowMs","activity","live","peak","delta","title","sources","models"]))
        let delta = try XCTUnwrap(body["delta"] as? [String: Any])
        XCTAssertEqual(delta["requests"] as? Int, 1)
        XCTAssertEqual(delta["output"] as? Int, 250)
        XCTAssertEqual(delta["measuredMs"] as? Int, 5000)
        XCTAssertNil(body["cost"]); XCTAssertNil(body["traffic"])
        XCTAssertEqual((body["client"] as? [String: Any])?["app"] as? String, "CodexTokenBar")
        XCTAssertNotNil(request.header("X-AgentSpeed-Signature"))
        XCTAssertNil(request.header("Authorization"))
        controller.setEnabled(false)
        XCTAssertEqual(monitor.stops, 1)
        clock = 10_000; controller.receive(snapshot)
        let after = await transport.requests()
        XCTAssertEqual(after.count, sent.count)
    }

    func testClaudeSourcesAreExcludedBeforeReportSerializationWhileCodexAndOtherSourcesRemain() throws {
        var counters = ReportCounters()
        counters.add(.init(requests: 5, output: 40, input: 80), to: .init(modelId: "claude-model", source: .claudeCode))
        counters.add(.init(requests: 7, output: 60, input: 100), to: .init(modelId: "desktop-model", source: .claudeDesktop))
        counters.add(.init(requests: 2, output: 12, input: 30), to: .init(modelId: "gpt-6.1-sol", source: .codex))
        counters.add(.init(requests: 4, output: 30, input: 50), to: .init(modelId: "deepseek-v3", source: .deepseek))
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        snapshot.live = .init(output: 1_027, total: 2_054)
        snapshot.liveEstimatedShare = 0.9
        snapshot.sources = [
            .init(kind: .claudeCode, enabled: true, rootPath: "", available: true, sessionCount: 1,
                  live: .init(output: 1_000, total: 2_000), today: .zero, activeAgents: 3,
                  liveEstimated: .init(output: 1_000, total: 2_000)),
            .init(kind: .claudeDesktop, enabled: true, rootPath: "", available: true, sessionCount: 1,
                  live: .init(output: 20, total: 40), today: .zero, activeAgents: 2,
                  liveEstimated: .init(output: 20, total: 40)),
            .init(kind: .codex, enabled: true, rootPath: "", available: true, sessionCount: 1,
                  live: .init(output: 20, total: 40), today: .zero, activeAgents: 1,
                  liveEstimated: .init(output: 5, total: 10)),
            .init(kind: .deepseek, enabled: true, rootPath: "", available: true, sessionCount: 1,
                  live: .init(output: 7, total: 14), today: .zero, activeAgents: 0,
                  liveEstimated: .init(output: 2, total: 4)),
        ]
        snapshot.report = .init(
            agents: [.claudeCode: .init(generating: 3), .claudeDesktop: .init(generating: 2), .codex: .init(generating: 1)],
            generatingModels: [
                .init(modelId: "claude-model", source: .claudeCode): 3,
                .init(modelId: "gpt-6.1-sol", source: .codex): 1,
            ],
            counters: counters
        )
        let mixed = ReportSample(snapshot: snapshot, traffic: .off)

        let safe = AgentSpeedReportingController.reportableSample(mixed)
        XCTAssertEqual(Set(safe.sources.keys), [.codex, .deepseek])
        XCTAssertEqual(safe.live.output, 27)
        XCTAssertEqual(safe.live.total, 54)
        XCTAssertEqual(safe.estimatedShare, 7.0 / 27.0, accuracy: 0.0001)
        XCTAssertEqual(safe.facts.counters.total.requests, 6)
        XCTAssertEqual(safe.facts.counters.total.output, 42)
        XCTAssertEqual(Set(safe.facts.agents.keys), [.codex])
        XCTAssertEqual(Set(safe.facts.generatingModels.keys.map(\.source)), [.codex])

        let window = ReportWindow(.init())
        let envelope = ReportEnvelope(
            client: AgentSpeedReportingController.client, deviceId: "device", username: "test-device",
            runId: "run", seq: 1, sentAtMs: 1_767_000_000_000, windowMs: 1_000,
            activity: .active, titleLevel: 0
        )
        let body = ReportBody.data(
            envelope, window.content(safe), safe,
            ReportOptions(sections: [.sources, .models], extensions: .init(modelHarnessRequests: true, executionModes: true))
        )
        XCTAssertTrue(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(body))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(text.contains("claudeCode"))
        XCTAssertFalse(text.contains("claudeDesktop"))
        XCTAssertTrue(text.contains("codex"))
        XCTAssertTrue(text.contains("deepseek"))
    }

    func testReportPayloadGuardRejectsClaudeUnknownAndUnattributedBodies() {
        XCTAssertTrue(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(
            Data(#"{"sources":[{"source":"codex"}],"models":[]}"#.utf8)
        ))
        XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(
            Data(#"{"sources":[{"source":"claudeCode"}],"models":[]}"#.utf8)
        ))
        XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(
            Data(#"{"sources":[{"source":"claudeDesktop"}],"models":[]}"#.utf8)
        ))
        XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(
            Data(#"{"sources":[{"source":"unrecognized"}],"models":[]}"#.utf8)
        ))
        XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(
            Data(#"{"schema":1,"delta":{"requests":10}}"#.utf8)
        ))
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
