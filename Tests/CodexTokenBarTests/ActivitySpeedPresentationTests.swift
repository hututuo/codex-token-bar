import XCTest
import AgentSpeedCore
@testable import CodexTokenBar

final class ActivitySpeedPresentationTests: XCTestCase {
    func testDefaultAndUnknownModeKeepBarAndEachClientContributesOnce() {
        XCTAssertEqual(ActivitySpeedDisplayMode.normalized(nil), .bar)
        XCTAssertEqual(ActivitySpeedDisplayMode.normalized("future"), .bar)
        let bar = [ModelRateContribution(model:"gpt-6-luna", tokensPerSecond:40)]
        let upstream = [ModelRateContribution(model:"gpt-6-luna", tokensPerSecond:90)]
        let claude = [ModelRateContribution(model:"claude-sonnet-4", tokensPerSecond:30)]
        let normal=ClientLocalRuntimePresentation.rates(codex:bar,claude:claude,allowed:["codex","claudeCode"],mode:.bar,upstreamCodex:upstream)
        XCTAssertEqual(normal.reduce(0){$0+$1.tokensPerSecond},70)
        let alternate=ClientLocalRuntimePresentation.rates(codex:bar,claude:claude,allowed:["codex","claudeCode"],mode:.agentSpeed,upstreamCodex:upstream)
        XCTAssertEqual(alternate.reduce(0){$0+$1.tokensPerSecond},120)
        XCTAssertEqual(ClientLocalRuntimePresentation.rates(codex:bar,claude:[],allowed:["codex"],mode:.agentSpeed),[])
    }
    @MainActor func testPoolSharesDefaultReaderAndDoesNotAdmitClaudeOrStartReporter() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var creates=0
        let pool=SharedAgentSpeedMonitorPool(onCreate:{_ in creates+=1})
        let first=pool.lease(store:SpeedStore(),sources:[.codex],codexRoot:root)
        let second=pool.lease(store:SpeedStore(),sources:[.codex],codexRoot:root)
        let denied=pool.lease(store:SpeedStore(),sources:[.claudeCode],codexRoot:root)
        first.start();second.start();denied.start()
        XCTAssertEqual(creates,1)
        first.stop(); second.stop(); denied.stop()
    }
    @MainActor func testRatesUseResponseModelsInsteadOfLatestAgentAndKeepUnknownRemainder() {
        var snapshot = SpeedSnapshot.empty
        snapshot.sources = [.init(kind: .codex, enabled: true, rootPath: "", available: true,
            sessionCount: 1, live: .init(output: 70, total: 120), today: .zero, activeAgents: 0)]
        snapshot.liveModels = [.init(source: .codex, model: "old-model", rate: .init(output: 40, total: 60)),
                               .init(source: .codex, model: "new-model", rate: .init(output: 20, total: 50)),
                               .init(source: .claudeCode, model: "unrelated", rate: .init(output: 500, total: 500))]
        let rates = AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: .codex)
        XCTAssertEqual(rates, [.init(model: "new-model", tokensPerSecond: 20),
                               .init(model: "old-model", tokensPerSecond: 40),
                               .init(model: "unknown", tokensPerSecond: 10)])
        snapshot.liveModels = []
        XCTAssertEqual(AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: .codex),
                       [.init(model: "unknown", tokensPerSecond: 70)])
    }

    @MainActor func testFloatingPointRemaindersDoNotCreateAnUnknownModel() {
        var snapshot = SpeedSnapshot.empty
        snapshot.sources = [.init(kind: .codex, enabled: true, rootPath: "", available: true,
            sessionCount: 1, live: .init(output: 70 + 1e-13, total: 120), today: .zero, activeAgents: 0)]
        snapshot.liveModels = [.init(source: .codex, model: "model", rate: .init(output: 70, total: 120)),
            .init(source: .codex, model: nil, rate: .init(output: 1e-14, total: 1e-14))]
        XCTAssertEqual(AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: .codex),
            [.init(model: "model", tokensPerSecond: 70)])
    }

}
