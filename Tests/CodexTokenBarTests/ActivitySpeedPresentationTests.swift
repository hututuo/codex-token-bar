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
}
