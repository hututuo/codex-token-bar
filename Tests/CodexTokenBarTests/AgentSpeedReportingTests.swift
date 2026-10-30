import AgentSpeedCore
import Foundation
import XCTest
@testable import CodexTokenBar

private actor SpeedReportTestTransport: ReportTransport {
    var gets = 0
    var sent: [ReportRequest] = []
    var held = false
    var alteredAPI = false
    var websocket = false
    var discoveryFailures = 0
    var registrationFailures = 0
    func failDiscovery(_ count: Int) { discoveryFailures = count }
    func failRegistration(_ count: Int) { registrationFailures = count }
    func offerWebSocket() { websocket = true }
    func holdDiscovery() { held = true }
    func alterAPI() { alteredAPI = true }
    func requests() -> [ReportRequest] { sent }
    func count() -> Int { gets + sent.count }
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        gets += 1
        if discoveryFailures > 0 { discoveryFailures -= 1; throw .offline }
        while held {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { throw .other(-999) }
        }
        let api = alteredAPI ? "https://other.example/api" : "https://speed-api.codexradar.com/api/agent-speed"
        let socketFields = websocket ? #","websocket":{"path":"/v1/reports/ws","subprotocol":"agent-speed-report.v1"}"# : ""
        return .init(status: 200, body: Data("""
        {"protocol":"agent-speed-report","versions":[1],"service":{"name":"test","terms":"https://deng.codexradar.com/agent-speed/terms/","privacy":"https://deng.codexradar.com/agent-speed/privacy/"},"api":"\(api)","apiKey":{"mode":"none"},"sections":["sources","models","cost","traffic"],"extensions":{"modelHarnessRequests":1,"executionModes":1,"profileAvatar":1,"sharedIdentity":1,"reportWebSocket":\(websocket ? 1 : 0)}\(socketFields)}
        """.utf8))
    }
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval)
        async throws(ReportTransportError) -> ReportHTTPResponse {
        sent.append(request)
        if request.url.path.hasSuffix("/devices") {
            if registrationFailures > 0 { registrationFailures -= 1; return .init(status:503,body:Data()) }
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
    func testTransientDiscoveryAutomaticallyRecoversWithoutChangingConsent() async throws {
        let prefs = defaults(), transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.failDiscovery(2)
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, makeMonitor: { _ in monitor },
            retryWait: { _ in try await Task.sleep(for: .milliseconds(30)) })
        controller.setEnabled(true, username: "RetryTest")
        try await waitFor { monitor.starts == 1 }
        XCTAssertTrue(controller.enabled); XCTAssertNil(controller.nextRetryAt)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/devices") }.count,1)
        controller.shutdown()
    }
    func testFailedRegistrationRetriesTheSameDeviceIdentity() async throws {
        let prefs = defaults(), transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.failRegistration(1)
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, makeMonitor: { _ in monitor },
            retryWait: { _ in try await Task.sleep(for: .milliseconds(30)) })
        controller.setEnabled(true, username: "RetryDevice")
        try await waitFor { monitor.starts == 1 }
        let bodies = await transport.requests().filter { $0.url.path.hasSuffix("/devices") }
            .compactMap { try? JSONSerialization.jsonObject(with:$0.body) as? [String:Any] }
        XCTAssertEqual(bodies.count,2)
        XCTAssertEqual(bodies[0]["deviceId"] as? String,bodies[1]["deviceId"] as? String)
        XCTAssertEqual(prefs.string(forKey:AgentSpeedReportingController.deviceKey),bodies[0]["deviceId"] as? String)
        controller.shutdown()
    }
    func testOptOutCancelsScheduledBootstrapRetry() async throws {
        let prefs = defaults(), transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.failDiscovery(20)
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, makeMonitor: { _ in monitor },
            retryWait: { _ in try await Task.sleep(for: .milliseconds(150)) })
        controller.setEnabled(true, username:"CancelRetry")
        try await waitFor { controller.nextRetryAt != nil }
        controller.setEnabled(false)
        let count = await transport.count()
        try await Task.sleep(for:.milliseconds(180))
        let after = await transport.count()
        XCTAssertEqual(count,after); XCTAssertEqual(monitor.starts,0)
        XCTAssertNil(controller.nextRetryAt); XCTAssertEqual(controller.phase,"off")
        controller.shutdown()
    }
    func testOuterRecoveryBackoffHonorsServiceDelayAndHardRejections() {
        XCTAssertEqual((0...8).map { AgentSpeedReportingController.recoveryDelay(attempt:$0) },[5,10,20,40,80,160,300,300,300])
        XCTAssertEqual(AgentSpeedReportingController.recoveryDelay(attempt:0,minimum:900),900)
        var limited = ReportReply(status:429); limited.retryAfterSeconds=90
        XCTAssertEqual(AgentSpeedReportingController.retryMinimum(.success(limited)),90)
        XCTAssertNil(AgentSpeedReportingController.retryMinimum(.success(.init(status:403,code:"forbidden"))))
        XCTAssertNil(AgentSpeedReportingController.retryMinimum(.success(.init(status:409,code:"username_taken"))))
    }
    func testDiscoveryErrorsDistinguishConnectionFailureFromUnsupportedService() {
        let connection = AgentSpeedReportingController.discoveryFailureMessage(.failed(.unreachable))
        XCTAssertTrue(connection.contains("超时"))
        XCTAssertTrue(connection.contains("代理"))
        XCTAssertFalse(connection.contains("已停止"))
        XCTAssertTrue(AgentSpeedReportingController.discoveryFailureMessage(.gone).contains("已停止"))
        XCTAssertTrue(AgentSpeedReportingController.discoveryFailureMessage(.invalid).contains("配置"))
        XCTAssertTrue(AgentSpeedReportingController.discoveryFailureMessage(.failed(.insecure)).contains("证书"))
    }
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

    func testLocalSourceConfigurationRespectsConsentAndClaudeDenyList() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport, makeMonitor: { _ in monitor })
        controller.start()
        let home = URL(fileURLWithPath: "/tmp/explicit-codex-home")
        controller.configureCodexHome(home)
        var preferences = MultiClientUsagePreference.defaults
        for index in preferences.indices {
            preferences[index].enabled = true
            if preferences[index].client == .deepseek { preferences[index].path = "/tmp/explicit-dsh-sessions" }
        }
        controller.configureLocalPreferences(preferences)
        XCTAssertEqual(controller.reportingConfiguration.codexRoot?.path, home.appendingPathComponent("sessions").path)
        XCTAssertEqual(controller.reportingConfiguration.dshRoot?.path, "/tmp/explicit-dsh-sessions")
        XCTAssertFalse(controller.reportingConfiguration.enabledSources.contains(.claudeCode))
        XCTAssertFalse(controller.reportingConfiguration.enabledSources.contains(.claudeDesktop))
        controller.configureCodexHome(nil)
        XCTAssertFalse(controller.reportingConfiguration.enabledSources.contains(.codex))
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(monitor.starts, 0)
        let calls = await transport.count()
        XCTAssertEqual(calls, 0)
    }

    func testOptedInReporterRestartsOnlyForActualRootChanges() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, makeMonitor: { _ in monitor })
        controller.start()
        controller.configureCodexHome(URL(fileURLWithPath: "/tmp/first-codex-home"))
        controller.setEnabled(true, username: "test-device")
        defer { controller.setEnabled(false) }
        try await waitFor { monitor.starts == 1 }
        let firstCalls = await transport.count()
        controller.configureCodexHome(URL(fileURLWithPath: "/tmp/first-codex-home"))
        controller.configureLocalPreferences(MultiClientUsagePreference.defaults)
        XCTAssertEqual(monitor.starts, 1)
        let unchangedCalls = await transport.count()
        XCTAssertEqual(unchangedCalls, firstCalls)
        controller.configureCodexHome(URL(fileURLWithPath: "/tmp/second-codex-home"))
        try await waitFor { monitor.starts == 2 }
        XCTAssertEqual(monitor.stops, 1)
        XCTAssertEqual(controller.reportingConfiguration.codexRoot?.path, "/tmp/second-codex-home/sessions")
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

    func testFilteredIdleWindowKeepsPriorPeakWithoutInventingCurrentSources() throws {
        let active = ReportSample(live: .init(output: 40, total: 80),
                                  sources: [.codex: .init(live: .init(output: 40, total: 80))])
        let envelope = ReportEnvelope(client: AgentSpeedReportingController.client, deviceId: "fixture",
            username: "Fixture", runId: "fixture", seq: 1, sentAtMs: 1_767_000_000_000,
            windowMs: 5000, activity: .idle, titleLevel: 0)
        for activeCount in [0, 1] {
            var window = ReportWindow(.init())
            window.observe(AgentSpeedReportingController.reportableSample(active))
            let idle = AgentSpeedReportingController.reportableSample(ReportSample(sources: [.codex: .init()],
                facts: .init(agents: [.codex: .init(active: activeCount)])))
            let body = ReportBody.data(envelope, window.take(idle), idle, .init(sections: [.sources, .models]))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertTrue((json["sources"] as? [Any])?.isEmpty == true)
            XCTAssertEqual((json["peak"] as? [String: Any])?["outputTokS"] as? Int, 40)
            XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(body))
            XCTAssertTrue(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(body, filteredWindow: true))
            // The next idle window contains only agents.active, which upstream
            // also deliberately omits from source-row activity.
            let next = ReportBody.data(envelope, window.take(idle), idle, .init(sections: [.sources, .models]))
            XCTAssertTrue(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(next, filteredWindow: true))
        }
        for text in [
            #"{"sources":[],"models":[],"live":{"outputTokS":1}}"#,
            #"{"sources":[],"models":[],"live":{"agents":{"generating":1}}}"#,
            #"{"sources":[],"models":[],"live":{"agents":{"tools":1}}}"#,
            #"{"sources":[],"models":[],"delta":{"output":1}}"#,
            #"{"sources":[{"source":"claudeCode"}],"peak":{"outputTokS":40}}"#,
            #"{"sources":[{"source":"claudeDesktop"}],"peak":{"outputTokS":40}}"#,
            #"{"sources":[{"source":"unknown"}],"peak":{"outputTokS":40}}"#
        ] {
            XCTAssertFalse(AgentSpeedReportingController.reportPayloadHasOnlyReportableSources(Data(text.utf8), filteredWindow: true))
        }
    }

    func testActiveToIdleToActiveKeepsReportingWithoutManualReconnect() async throws {
        let transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        var clock: Int64 = 0
        let controller = AgentSpeedReportingController(defaults: defaults(), transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, monotonic: { clock }, makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: "IdleRecovery")
        defer { controller.shutdown() }
        try await waitFor { monitor.starts == 1 }
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        func emit(_ at: Int64, rate: Double, settled: Bool = false) {
            clock = at
            snapshot.live = .init(output: rate, total: rate * 2)
            snapshot.sources = [.init(kind: .codex, enabled: true, rootPath: "", available: true,
                sessionCount: 1, live: snapshot.live, today: .zero, activeAgents: 1)]
            snapshot.report.agents = [.codex: .init(active: 1)]
            if settled { snapshot.report.counters.add(.init(requests: 1, output: 100),
                to: .init(modelId: "gpt-6.1-sol", source: .codex)) }
            controller.receive(snapshot)
        }
        emit(0, rate: 40); emit(1000, rate: 40); emit(5000, rate: 0)
        try await waitFor { controller.lastReportAt != nil || controller.phase == "error" }
        XCTAssertNotEqual(controller.phase, "error", controller.message)
        // Await the accepted request before the next scheduler step.
        for (at, rate, settled) in [(Int64(10000), 0.0, false), (15000, 45.0, true)] {
            emit(at, rate: rate, settled: settled)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNotEqual(controller.phase, "error", controller.message)
        }
        let requests = await transport.requests()
        let reports = requests.filter { $0.url.path.hasSuffix("/reports") }
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/devices") }.count, 1)
        XCTAssertEqual(monitor.starts, 1); XCTAssertEqual(monitor.stops, 0)
        let last = try XCTUnwrap(reports.last)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: last.body) as? [String: Any])
        XCTAssertEqual((json["delta"] as? [String: Any])?["output"] as? Int, 100)
    }

    func testFailedNicknameCannotGrantConsent() {
        let prefs = defaults()
        let controller = AgentSpeedReportingController(defaults: prefs)
        controller.setEnabled(true, username: "!")
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(prefs.bool(forKey: AgentSpeedReportingController.enabledKey))
    }

    func testSocketFailureFallsBackWithoutReplayingAndRetainsDeviceAndPreference() async throws {
        let prefs = defaults(), transport = SpeedReportTestTransport(), monitor = SpeedReportTestMonitor()
        await transport.offerWebSocket()
        prefs.set("websocket", forKey: AgentSpeedReportingController.transportKey)
        var clock: Int64 = 0
        var socket: AgentSpeedWebSocket?
        let controller = AgentSpeedReportingController(defaults: prefs, transport: transport,
            makeSigner: { _ in SoftwareReportSigner() }, monotonic: { clock },
            startWebSocket: { socket = $0 }, makeRealtimeMonitor: { _ in monitor }, makeMonitor: { _ in monitor })
        controller.setEnabled(true, username: "fallback-test")
        try await waitFor { monitor.starts == 1 }
        let initialSocket = try XCTUnwrap(socket)
        var snapshot = SpeedSnapshot.empty
        snapshot.state = .running
        let model = ReportModelKey(modelId: "gpt-6.1-sol", source: .codex)
        snapshot.report.counters.add(.init(requests: 10, output: 1000, costMicroUsd: 90_000), to: model)
        controller.receive(snapshot)
        // Switching channels must not carry the existing WS-side counters into HTTP.
        XCTAssertTrue(initialSocket.ledger.pending.isEmpty)
        initialSocket.onTransportUnavailable?()
        XCTAssertTrue(controller.usingHTTPFallback)
        XCTAssertTrue(controller.message.contains("HTTP"))
        controller.receive(snapshot) // fresh HTTP baseline
        snapshot.live = .init(output: 50, total: 100)
        controller.receive(snapshot)
        snapshot.report.counters.add(.init(requests: 1, output: 250, measuredOutput: 250,
                                          measuredMs: 5000, costMicroUsd: 1234, unpricedRequests: 1), to: model)
        clock = 5000
        controller.receive(snapshot)
        try await waitFor { controller.lastReportAt != nil }
        let requests = await transport.requests()
        let registration = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("/devices") })
        let registered = try XCTUnwrap(JSONSerialization.jsonObject(with: registration.body) as? [String: Any])
        let reports = requests.filter { $0.url.path.hasSuffix("/reports") }
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: report.body) as? [String: Any])
        XCTAssertEqual(body["deviceId"] as? String, registered["deviceId"] as? String)
        XCTAssertNotEqual((body["run"] as? [String: Any])?["id"] as? String, initialSocket.runID)
        XCTAssertEqual((body["delta"] as? [String: Any])?["output"] as? Int, 250)
        XCTAssertEqual((body["cost"] as? [String: Any])?["deltaMicroUsd"] as? Int, 1234)
        XCTAssertEqual((body["cost"] as? [String: Any])?["unpricedRequests"] as? Int, 1)
        XCTAssertNotNil(report.header("X-AgentSpeed-Signature"))
        XCTAssertEqual(controller.transport, .websocket)
        XCTAssertEqual(prefs.string(forKey: AgentSpeedReportingController.transportKey), "websocket")
        XCTAssertTrue(controller.message.contains("已回退 HTTP"))
        controller.retry()
        XCTAssertFalse(controller.usingHTTPFallback)
        try await waitFor { monitor.starts == 2 }
        XCTAssertEqual(controller.transport, .websocket)
        controller.setEnabled(false)
        let count = await transport.requests().count
        initialSocket.onTransportUnavailable?()
        controller.receive(snapshot)
        let finalCount = await transport.requests().count
        XCTAssertEqual(finalCount, count)
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
