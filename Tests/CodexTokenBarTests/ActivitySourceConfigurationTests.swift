import AgentSpeedCore
import XCTest
@testable import CodexTokenBar

final class ActivitySourceConfigurationTests: XCTestCase {
    func testEnabledClientRootsDoNotImplicitlyEnableClaudeOrOtherClients() {
        let home = URL(fileURLWithPath: "/tmp/tokenbar-fixture-home")
        var prefs = MultiClientUsagePreference.defaults
        for index in prefs.indices {
            prefs[index].enabled = prefs[index].client == .deepseek || prefs[index].client == .claudeCode
            if prefs[index].client == .deepseek { prefs[index].path = "/tmp/dsh-sessions" }
        }
        let config = ActivitySourceConfiguration.make(codexEnabled: false, codexHome: nil, preferences: prefs, home: home, environment: [:])
        XCTAssertEqual(config.sources, [.deepseek])
        XCTAssertEqual(config.deepseekRoot.path, "/tmp/dsh-sessions")
        XCTAssertFalse(config.monitorConfiguration.enabledSources.contains(.claudeCode))
        XCTAssertFalse(config.monitorConfiguration.enabledSources.contains(.codex))
        XCTAssertNotNil(config.identity(for: .deepseek))
        XCTAssertNil(config.identity(for: .claudeCode))
    }
    func testRootConfigurationMatchesHistoryEnvironmentAndOpenCodeFileSelection() {
        let home = URL(fileURLWithPath: "/tmp/tokenbar-fixture-home")
        var prefs = MultiClientUsagePreference.defaults
        for index in prefs.indices where prefs[index].client == .opencode {
            prefs[index].enabled = true; prefs[index].path = "/tmp/opencode-store/opencode.db"
        }
        let config = ActivitySourceConfiguration.make(codexEnabled: true, codexHome: home.appendingPathComponent("codex"),
            preferences: prefs, home: home, environment: ["DSH_HOME":"/tmp/dsh-home", "GEMINI_CLI_HOME":"/tmp/gemini-home"])
        XCTAssertEqual(config.sources, [.codex, .opencode])
        XCTAssertEqual(config.codexRoot.path, home.appendingPathComponent("codex/sessions").path)
        XCTAssertEqual(config.deepseekRoot.path, "/tmp/dsh-home/sessions")
        XCTAssertEqual(config.geminiRoot.path, "/tmp/gemini-home/.gemini/tmp")
        XCTAssertEqual(config.opencodeRoot.path, "/tmp/opencode-store")
        XCTAssertEqual(config.identity(for: .codex), ActivitySpeedSourceIdentity.root(home.appendingPathComponent("codex")))
    }
    func testOtherClientRatesJoinSelectedCodexAlgorithmExactlyOnce() {
        let bar = [ModelRateContribution(model: "gpt-6-luna", tokensPerSecond: 40)]
        let upstream = [ModelRateContribution(model: "gpt-6-luna", tokensPerSecond: 90)]
        let others = [ModelRateContribution(model: "deepseek-v3", tokensPerSecond: 30)]
        for (mode, expected) in [(ActivitySpeedDisplayMode.bar, 70.0), (.agentSpeed, 120.0)] {
            let result = ClientLocalRuntimePresentation.rates(codex: bar, claude: [], allowed: ["codex", "deepseek"],
                mode: mode, upstreamCodex: upstream, others: others)
            XCTAssertEqual(result.reduce(0) { $0 + $1.tokensPerSecond }, expected)
        }
    }
}
