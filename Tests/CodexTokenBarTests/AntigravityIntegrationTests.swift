import AgentSpeedCore
import XCTest
@testable import CodexTokenBar

final class AntigravityIntegrationTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/AgentSpeed/spec/fixtures")
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-antigravity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testFixturesReachLedgerExactlyOnceAndPreservePricingAndForkRules() throws {
        let root = try temporary(), ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ledger.sqlite"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("parser-expected.json"))) as? [String: Any])
        let gravity = try XCTUnwrap(expected["antigravity"] as? [String: Any])
        let order = try XCTUnwrap(gravity["order"] as? [String])
        let databases = try XCTUnwrap(gravity["databases"] as? [String: [String: Any]])
        var known = Set<String>()
        for relative in order {
            let source = fixtures.appendingPathComponent(relative)
            let wanted = try XCTUnwrap(databases[relative])
            if wanted["unsupported"] as? Bool == true {
                XCTAssertThrowsError(try AntigravityUsageSource.read(source)); continue
            }
            let rows = try AntigravityUsageSource.read(source).events
            let unique = rows.filter { known.insert($0.eventID).inserted }
            let responses = try XCTUnwrap(wanted["responses"] as? [[String: Any]])
            XCTAssertEqual(unique.count, responses.count, relative)
            for row in unique {
                let match = try XCTUnwrap(responses.first { "antigravity:" + ($0["key"] as? String ?? "") == row.eventID })
                XCTAssertEqual(row.inputTokens, (match["input"] as? NSNumber)?.int64Value)
                XCTAssertEqual(row.outputTokens, (match["output"] as? NSNumber)?.int64Value)
                XCTAssertEqual(row.cacheReadTokens, (match["cachedInput"] as? NSNumber)?.int64Value)
                XCTAssertEqual(row.reasoningTokens, (match["reasoning"] as? NSNumber)?.int64Value)
                XCTAssertEqual(row.model, match["model"] as? String ?? "unknown")
            }
            _ = try ledger.ingest(rows)
            XCTAssertEqual(try ledger.ingest(rows), 0)
        }
        let summary = try ledger.summaries()
        XCTAssertEqual(summary.reduce(0) { $0 + $1.requests }, 16)
        XCTAssertEqual(summary.reduce(Int64(0)) { $0 + $1.inputTokens }, 106830)
        XCTAssertEqual(summary.reduce(Int64(0)) { $0 + $1.outputTokens }, 3357)
        // Parser fixtures use an older fixture price book. The current product table
        // intentionally leaves undocumented Antigravity routing labels unpriced.
        XCTAssertGreaterThan(summary.reduce(0) { $0 + $1.unpricedRequests }, 0)
        XCTAssertGreaterThan(summary.compactMap(\.apiCostUSD).reduce(0, +), 0)
    }

    func testProductionScannerDiscoversThreeStoresAndKeepsOldLedgerWhenDisabled() async throws {
        let root = try temporary()
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("antigravity"), to: root.appendingPathComponent(".gemini"))
        let discovery = AntigravityUsageSource.discover(home: root)
        XCTAssertEqual(discovery.files.count, 11)
        XCTAssertFalse(discovery.files.contains { $0.path.contains("-backup") || $0.path.contains("/old/") || $0.pathExtension != "db" })
        XCTAssertTrue(AntigravityUsageSource.discover(home: root, path: root.appendingPathComponent(".gemini/antigravity-backup").path).files.isEmpty)
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("ledger.sqlite"), home: root, environment: [:])
        var preferences = MultiClientUsagePreference.defaults
        let index = try XCTUnwrap(preferences.firstIndex { $0.client == .antigravity })
        preferences[index].enabled = true
        let first = try await scanner.scan(preferences)
        let second = try await scanner.scan(preferences)
        XCTAssertEqual(first.summaries, second.summaries)
        XCTAssertEqual(first.summaries.reduce(0) { $0 + $1.requests }, 16)
        preferences[index].enabled = false
        let disabled = try await scanner.scan(preferences)
        XCTAssertEqual(disabled.summaries, first.summaries)
    }

    func testWALCompletionAndLateModelUpdateReachSameLedgerEvent() async throws {
        let root = try temporary(), store = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let file = store.appendingPathComponent("11111111-2222-4333-8444-555555555555.db")
        let writer = SQLiteDatabaseDriver(url: file)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,metadata BLOB)")
        try writer.execute("CREATE TABLE executor_metadata(idx INTEGER,data BLOB)")
        func varint(_ input: UInt64) -> [UInt8] { var n=input, bytes:[UInt8]=[]; repeat { let byte=UInt8(n & 127); n >>= 7; bytes.append(byte | (n > 0 ? 128 : 0)) } while n > 0; return bytes }
        func uint(_ key: UInt64, _ n: UInt64) -> [UInt8] { varint(key << 3) + varint(n) }
        func blob(_ key: UInt64, _ bytes: [UInt8]) -> [UInt8] { varint((key << 3) | 2) + varint(UInt64(bytes.count)) + bytes }
        let metadata = Data(blob(1, uint(1, 1_793_000_000)) + blob(7, uint(1, 1_793_000_003)) + blob(9, uint(2, 100) + uint(3, 20) + uint(5, 40) + uint(9, 5) + blob(11, Array("wal-response".utf8))))
        try writer.execute("INSERT INTO steps VALUES(1,15,8,?)", bindings: [.blob(metadata)])
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("ledger.sqlite"), home: root, environment: [:])
        var preference = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .antigravity })
        preference.enabled = true; preference.path = store.path
        let open = try await scanner.scan([preference]); XCTAssertTrue(open.summaries.isEmpty)
        try writer.execute("UPDATE steps SET status=3")
        let complete = try await scanner.scan([preference]); XCTAssertEqual(complete.summaries.first?.requests, 1)
        XCTAssertEqual(complete.summaries.first?.inputTokens, 140)
        XCTAssertEqual(complete.summaries.first?.outputTokens, 20)
        XCTAssertEqual(complete.summaries.first?.unpricedRequests, 1)
        let executor = Data(uint(3, 1) + blob(10, blob(1, blob(28, Array("gemini-4-argon".utf8)))))
        try writer.execute("INSERT INTO executor_metadata VALUES(0,?)", bindings: [.blob(executor)])
        let named = try await scanner.scan([preference])
        XCTAssertEqual(named.summaries.first?.requests, 1)
        XCTAssertEqual(named.summaries.first?.model, "gemini-4-argon")
        XCTAssertEqual(named.summaries.first?.unpricedRequests, 0)
        XCTAssertGreaterThan(named.summaries.first?.apiCostUSD ?? 0, 0)
    }

    func testPublishedEffortModifiersArePricedWithoutGuessingRouterAliases() throws {
        for (raw, expected) in [("gemini-4-argon-high", "gemini-4-argon"), ("claude-opus-4-6-thinking", "claude-opus-4-6"),
            ("gemini-3.8-flash-n", "gemini-3.8-flash-n"), ("gemini-pro-default", "gemini-pro-default"), ("private-model-high", "private-model-high")] {
            XCTAssertEqual(AntigravityUsageSource.priceModel(for: raw), expected)
        }
        let root = try temporary(), ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ledger.sqlite"))
        let rows = ["gemini-4-argon-high", "gemini-4-argon", "gemini-3.8-flash-n"].map {
            ClientUsageEvent(client: .antigravity, eventID: $0, sessionID: "s", model: $0, timestamp: Date(timeIntervalSince1970: 1793000000), inputTokens: 140, outputTokens: 20, cacheReadTokens: 40, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest(rows)
        let summaries = try ledger.summaries()
        let base = try XCTUnwrap(summaries.first { $0.model == "gemini-4-argon" }?.apiCostUSD)
        XCTAssertEqual(summaries.first { $0.model == "gemini-4-argon-high" }?.apiCostUSD, base)
        XCTAssertNil(summaries.first { $0.model == "gemini-3.8-flash-n" }?.apiCostUSD)
    }

    @MainActor func testAntigravityTasksRatesAndModelColorsUseSharedPresentation() throws {
        var preferences = MultiClientUsagePreference.defaults
        let index = try XCTUnwrap(preferences.firstIndex { $0.client == .antigravity })
        preferences[index].enabled = true
        let config = ActivitySourceConfiguration.make(codexEnabled: false, codexHome: nil, preferences: preferences)
        XCTAssertEqual(config.sources, [.antigravity]); XCTAssertNil(config.monitorConfiguration.antigravityRoot)
        preferences[index].path = "/tmp/gravity/conversations"
        XCTAssertEqual(ActivitySourceConfiguration.make(codexEnabled: false, codexHome: nil, preferences: preferences).monitorConfiguration.antigravityRoot?.path, "/tmp/gravity/conversations")
        let now = Date(), model = "gemini-4-argon"
        var snapshot = SpeedSnapshot.empty
        snapshot.timestamp = now; snapshot.state = .running
        snapshot.sources = [.init(kind: .antigravity, enabled: true, rootPath: "/fixture", available: true, sessionCount: 2, live: .init(output: 40, total: 60), today: .zero, activeAgents: 2)]
        snapshot.agents = [
            .init(id: "parent", source: .antigravity, project: "", model: model, phase: .generating, isSubagent: false, live: .init(output: 40, total: 60), recentSpeed: nil, lastActivity: now),
            .init(id: "child", source: .antigravity, project: "", model: model, phase: .tools, isSubagent: true, live: .zero, recentSpeed: nil, lastActivity: now, parentId: "parent")]
        snapshot.liveModels = [.init(source: .antigravity, model: model, rate: .init(output: 40, total: 60))]
        let running = ClientLocalRuntimePresentation.antigravityRunning(snapshot, now: now)
        XCTAssertEqual(running.main, 1); XCTAssertEqual(running.subagents, 1)
        XCTAssertEqual(running.groups.first?.subagents.count, 1)
        XCTAssertEqual(running.groups.first?.mainThread.title, "Antigravity session")
        let merged = ClientLocalRuntimePresentation.running(codex: .unavailable, claude: .unavailable, allowed: ["antigravity"], antigravity: running)
        XCTAssertEqual(merged.main, 1); XCTAssertEqual(merged.subagents, 1)
        let meter = SidebarTaskMeterPresentation(summary: merged)
        XCTAssertEqual(meter.cells.compactMap { $0 }.count, 2)
        XCTAssertEqual(meter.color(at: 0), ModelUsagePresentation.color(for: model))
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for: model, latest: false), ModelUsagePresentation.colorHex(for: model))
        XCTAssertEqual(AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: .antigravity, now: now).first?.tokensPerSecond, 40)
        snapshot.agents = snapshot.agents.map { var agent=$0; agent.phase = .idle; return agent }
        XCTAssertEqual(ClientLocalRuntimePresentation.antigravityRunning(snapshot, now: now).main, 0)
        XCTAssertTrue(AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: .antigravity, now: now).isEmpty)
        XCTAssertEqual(ClientLocalRuntimePresentation.antigravityRunning(snapshot, now: now.addingTimeInterval(10)).freshness, .unavailable)
    }

    func testReadOnlyLocalAcceptanceWhenExplicitlyRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["TOKENBAR_ANTIGRAVITY_ACCEPTANCE_OUTPUT"] else {
            throw XCTSkip("Opt-in local source acceptance; writes only an isolated temporary ledger")
        }
        let root = try temporary(), home = FileManager.default.homeDirectoryForCurrentUser
        let discovery = AntigravityUsageSource.discover(home: home)
        XCTAssertFalse(discovery.files.isEmpty)
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("ledger.sqlite"), home: home)
        var preference = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .antigravity })
        preference.enabled = true
        let started = Date()
        var result = MultiClientScanResult(summaries: [], diagnostics: [])
        let passes = max(1, (discovery.files.count + 199) / 200)
        for _ in 0..<passes { result = try await scanner.scan([preference]) }
        let firstSeconds = Date().timeIntervalSince(started)
        let repeatStart = Date()
        let repeated = try await scanner.scan([preference])
        XCTAssertGreaterThan(result.summaries.reduce(0) { $0 + $1.requests }, 0)
        let evidence: [String: Any] = [
            "sampledAt": ISO8601DateFormatter().string(from: Date()), "sourceReadOnly": true,
            "isolatedLedger": true, "discoveredDatabases": discovery.files.count, "initialPasses": passes,
            "initialScanSeconds": firstSeconds, "oneRepeatPassSeconds": Date().timeIntervalSince(repeatStart),
            "requests": result.summaries.reduce(0) { $0 + $1.requests },
            "repeatRequests": repeated.summaries.reduce(0) { $0 + $1.requests },
            "inputTokens": result.summaries.reduce(Int64(0)) { $0 + $1.inputTokens },
            "outputTokens": result.summaries.reduce(Int64(0)) { $0 + $1.outputTokens },
            "knownReferenceCostUSD": result.summaries.compactMap(\.apiCostUSD).reduce(0, +),
            "unpricedRequests": result.summaries.reduce(0) { $0 + $1.unpricedRequests },
            "models": result.summaries.map { ["model":$0.model,"requests":$0.requests,"unpricedRequests":$0.unpricedRequests] },
            "diagnostics": result.diagnostics,
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
