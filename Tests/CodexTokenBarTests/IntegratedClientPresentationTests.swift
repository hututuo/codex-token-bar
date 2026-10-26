import XCTest
@testable import CodexTokenBar

final class IntegratedClientPresentationTests: XCTestCase {
    func testPreviewQuotaIsExplicitDisplayOnlyAndKeepsProSingleWindow() {
        let source = AccountQuotaSnapshot.empty
        let reading = ClaudeCapturedQuotaProvider(snapshot: .missing).reading()
        let real = ClientQuotaProjection.items(codex: source, claude: reading, includeClaude: true)
        XCTAssertTrue(real.allSatisfy { $0.remaining == nil })
        let preview = ClientQuotaProjection.items(codex: source, claude: reading, includeClaude: true, preview: true)
        XCTAssertEqual(preview.map(\.remaining), [72, 62, 84])
        XCTAssertEqual(preview.map(\.windowTitle), ["7天", "5小时", "7天"])
        XCTAssertEqual(preview.map(\.id), ["codex:7d", "claudeCode:5h", "claudeCode:7d"])
        XCTAssertNil(ClientQuotaRingGroup.make(preview)[0].right)
        XCTAssertNil(source.sevenDay)
        XCTAssertTrue(preview.allSatisfy { $0.source.contains("模拟") })
        XCTAssertEqual(ClientQuotaProjection.previewItems(includeClaude: false).count, 1)
    }
    func testBrandCapAndQuotaFillHaveIndependentMeaningAndDoNotGrowRailSlot() {
        let items = ClientQuotaProjection.previewItems(includeClaude: true)
        XCTAssertEqual(items[1].brand, items[2].brand)
        XCTAssertNotEqual(items[1].fill, items[2].fill)
        for item in items { XCTAssertNotEqual(item.fill, item.brand) }
        for total in [8.0, 24, 46] {
            XCTAssertEqual(ClientSidebarMetrics.trackHeight(total), total)
        }
        XCTAssertEqual(ClientSidebarMetrics.capWidth, ClientSidebarMetrics.capHeight * 2)
        XCTAssertEqual(ClientSidebarMetrics.capGap, 0)
        XCTAssertEqual(ClientSidebarMetrics.ringSize, 46)
    }
    func testPersistedScopeDoesNotFlashCodexWhileClientSnapshotLoads() {
        XCTAssertEqual(ClientDisplayScope.clients("claudeCode", available: []), ["claudeCode"])
        XCTAssertEqual(ClientDisplayScope.clients("all", available: ["gemini", "gemini"]), ["codex", "gemini"])
        XCTAssertEqual(ClientDisplayScope.clients("corrupt", available: []), ["codex"])
    }
    func testQuotaUnknownIsNotZeroAndWindowsAreNeverAveraged() {
        let snapshot = AccountQuotaSnapshot(fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 100, resetsAt: nil),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 8, resetsAt: nil))
        let items = ClientQuotaProjection.items(codex: snapshot,
            claude: ClaudeCapturedQuotaProvider(snapshot: .missing).reading(), includeClaude: true)
        XCTAssertEqual(items.map(\.id), ["codex:5h", "codex:7d", "claudeCode:5h", "claudeCode:7d"])
        XCTAssertEqual(items[0].value, "0%")
        XCTAssertEqual(items[1].value, "92%")
        XCTAssertNil(items[2].remaining)
        XCTAssertEqual(items[2].value, "—")
        XCTAssertEqual(items[2].status, "未接入")
    }
    func testQuotaPreferencesRoundTripRetainEverySelectedItemAndHiddenHistory() {
        var s = ClientQuotaSelection()
        let items = (0..<20).map { i in ClientQuotaItem(id: "claudeCode:\(i)", client: "claudeCode", window: "\(i)", remaining: nil, resetsAt: nil, source: "local", status: "未接入") }
        s.enabled = Set(items.map(\.id)); s.order = items.map(\.id).reversed(); s.hidden = [items[3].id]
        s.colors[items[4].id] = "#123456"
        let restored = ClientQuotaSelection.decode(s.encoded)
        XCTAssertEqual(restored, s)
        XCTAssertEqual(restored.arranged(items).count, 20)
        XCTAssertEqual(restored.arranged(items).filter(restored.includes).count, 19)
        XCTAssertTrue(items.allSatisfy { $0.remaining == nil }, "display preferences cannot alter facts")
    }
    func testProSingleWindowUsesWholeRingAndClaudeTwoWindowsStayTogether() {
        let codex = ClientQuotaItem(id: "codex:7d", client: "codex", window: "7d", remaining: 92, resetsAt: nil, source: "local", status: "")
        let claude = ["5h", "7d"].map { ClientQuotaItem(id: "claudeCode:" + $0, client: "claudeCode", window: $0, remaining: nil, resetsAt: nil, source: "local", status: "未接入") }
        let items = [codex] + claude
        let groups = ClientQuotaRingGroup.make(items)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNil(groups[0].right, "No five-hour window means one full PRO ring, never half an empty pair")
        XCTAssertEqual(groups[1].left.id, "claudeCode:5h")
        XCTAssertEqual(groups[1].right?.id, "claudeCode:7d")
        let combined = ClientQuotaRingGroup.make(items, acrossClients: true)
        XCTAssertEqual(combined[0].right?.client, "claudeCode")
        let legacy = ClientQuotaSelection.decode("{\"order\":[\"codex:7d\"],\"hidden\":[],\"enabled\":[],\"colors\":{}}")
        XCTAssertFalse(legacy.pairAcrossClients)
        XCTAssertEqual(legacy.order, ["codex:7d"])
    }

    func testUnknownCacheCoverageDoesNotDiluteKnownCacheRate() {
        let known = ClientUsageSummary(client: .claudeCode, model: "model", inputTokens: 100,
            outputTokens: 20, cacheReadTokens: 80, cacheWriteTokens: nil, reasoningTokens: nil,
            requests: 1, lastSeen: Date(), incompleteFields: false, cacheReadComplete: true)
        let partial = ClientUsageSummary(client: .gemini, model: "model", inputTokens: 1000,
            outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: nil, reasoningTokens: nil,
            requests: 2, lastSeen: Date(), incompleteFields: true, cacheReadComplete: false)
        let covered = ClientCacheCoverage.make(codex: .empty, rows: [known, partial], allowed: ["claudeCode", "gemini"])
        XCTAssertEqual(covered.input, 100)
        XCTAssertEqual(covered.cached, 80)
        XCTAssertEqual(covered.unknownInput, 1000)
        XCTAssertEqual(covered.ratio, 0.8)
        XCTAssertNil(ClientCacheCoverage.make(codex: .empty, rows: [partial], allowed: ["gemini"]).ratio)
    }

    func testMoneyDistinguishesUnknownFreeAndSubCentAmount() {
        XCTAssertEqual(ClientMoney.text(nil), "未计价")
        XCTAssertEqual(ClientMoney.text(.nan), "未计价")
        XCTAssertEqual(ClientMoney.text(0), "$0.00")
        XCTAssertEqual(ClientMoney.text(0.001), "<$0.01")
    }

    func testThirtyDayProjectionKeepsFirstPartialBucket() {
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let cutoff = now.timeIntervalSince1970 - 30 * 86400
        let row = ClientTrendBucket(client: .claudeCode, startUnix: Int64(floor(cutoff / 300) * 300), inputTokens: 13, outputTokens: 7, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil, requests: 1)
        let points = ClientUsageChartProjection.points(codex: [], others: [row], days: 30, now: now, allowed: ["claudeCode"])
        XCTAssertEqual(points.reduce(0) { $0 + $1.tokens }, 20)
    }

    func testRailFitsWorkingAreaAndHasNoItemCountLimit() {
        XCTAssertEqual(ClientRailLayout.make(quotaCount: 0, mode: "auto", hasFiveHour: false, availableHeight: 900).height, 134)
        XCTAssertFalse(ClientRailLayout.make(quotaCount: 2, mode: "auto", hasFiveHour: false, availableHeight: 900).short, "Claude two-window rail uses the original dual-window recommendation")
        for count in [0, 1, 2, 4, 6, 10, 50, 500] {
            for mode in ["auto", "long", "short"] {
                let layout = ClientRailLayout.make(quotaCount: count, mode: mode, hasFiveHour: true, availableHeight: 620)
                XCTAssertLessThanOrEqual(layout.height, 620)
                XCTAssertGreaterThanOrEqual(layout.barHeight, 8)
            }
        }
        XCTAssertFalse(ClientRailLayout.make(quotaCount: 2, mode: "auto", hasFiveHour: true, availableHeight: 900).short)
        XCTAssertTrue(ClientRailLayout.make(quotaCount: 4, mode: "auto", hasFiveHour: true, availableHeight: 900).short)
        XCTAssertFalse(ClientRailLayout.make(quotaCount: 10, mode: "long", hasFiveHour: true, availableHeight: 900).short)
    }
    func testNativeCompactHeightClampsToEachMonitorWithoutMovingTheDockedEdge() {
        let area = CGRect(x: -1440, y: -240, width: 1440, height: 720)
        for edge in [QuotaSidebarEdge.left, .right] {
            let frames = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false, compactHeight: 1200)
            XCTAssertEqual(frames.rail.height, 720)
            XCTAssertEqual(frames.rail.width, 16)
            XCTAssertTrue(area.contains(frames.rail))
        }
    }
}
