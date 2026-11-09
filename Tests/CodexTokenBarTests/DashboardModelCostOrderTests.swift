import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardModelCostOrderTests: XCTestCase {
    func testChannelThinkingAliasesShareDisplayColorWithoutChangingBillingIdentity() {
        for family in ["Opus", "Sonnet"] {
            let raw = "Claude \(family) 4.6 (Thinking)"
            let canonical = "claude-\(family.lowercased())-4-6"
            XCTAssertEqual(ModelUsagePresentation.key(for: raw), raw, "Ledger grouping keys retain source identity")
            XCTAssertEqual(ModelPresentationIdentity.resolve(raw).key, canonical)
            XCTAssertEqual(ModelUsagePresentation.label(for: raw), ModelPresentationIdentity.resolve(raw).label)
            XCTAssertEqual(ModelUsagePresentation.colorHex(for: raw), ModelUsagePresentation.colorHex(for: canonical))
            XCTAssertEqual(DashboardModelCostOrder.groupID(item("antigravity|" + raw)), "recent")
            XCTAssertEqual(DashboardModelCostOrder.groupID(item("claudeCode|" + raw)), "claude")
            XCTAssertEqual(ModelPresentationIdentity.billingIdentifier(raw.lowercased()), raw.lowercased())
        }
        for (key, color) in ModelPresentationIdentity.colors { XCTAssertEqual(ModelUsagePresentation.colorHex(for: key), color) }
        for (key, color) in ModelPresentationIdentity.clientColors { XCTAssertEqual(ModelUsagePresentation.colorHex(for: key), color) }
    }
    struct Fixture: Decodable {
        struct Group: Decodable { let id: String; let keys: [String] }
        let input: [String]; let groups: [Group]
    }
    func item(_ id: String, tokens: Int = 100) -> FloatingTodayModelUsageItem {
        .init(id: id, label: id == "unknown-models" ? "未知模型" : ModelPresentationIdentity.resolve(id.split(separator: "|").last.map(String.init)).label,
              tokens: tokens, share: 0.001, costUSD: id == "unknown-models" ? nil : 0.25,
              usesIndependentQuota: false, referenceCostUSD: id == "unknown-models" ? 18.9 : nil, color: .blue)
    }
    func testSharedCostOrderPreservesEverySourceAndAmountAcrossPeriods() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/model-cost-order.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let rows = fixture.input.map { item($0) }
        let periods = ClientModelCostPeriods(lifetime: rows, today: Array(rows.reversed()), sevenDay: Array(rows.dropFirst()) + [rows[0]])
        for scope in [DashboardModelCostScope.lifetime, .today, .sevenDay] {
            let groups = periods.groups(scope)
            XCTAssertEqual(groups.map(\.id), fixture.groups.map(\.id))
            XCTAssertEqual(groups.map { $0.items.map(\.id) }, fixture.groups.map(\.keys))
            XCTAssertEqual(groups.flatMap(\.items).sorted { $0.id < $1.id }, rows.sorted { $0.id < $1.id })
        }
        XCTAssertTrue(DashboardModelCostOrder.groups([item("claudeCode|claude-fable-5-1", tokens: 0)]).isEmpty)
        XCTAssertEqual(DashboardModelCostOrder.policy.groups.first?.models, [
            "gemini-4-argon", "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5",
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"
        ])
        XCTAssertFalse(DashboardModelCostOrder.policy.groups.contains { $0.id == "fable" })
        XCTAssertFalse(DashboardModelCostOrder.groups([item("codex|gpt-6-sol")]).contains { $0.id == "latest" })
    }
    @MainActor
    func testShortPeriodFillsFourSlotsAndUnknownNameFitsSingleRow() throws {
        let unknown = item("unknown-models", tokens: 13_662_755)
        XCTAssertEqual(DashboardModelCostGrid(items: [unknown], fillFirstRow: true).slotCount, 4)
        XCTAssertEqual(DashboardModelCostGrid(items: [], fillFirstRow: true).slotCount, 4)
        XCTAssertEqual(DashboardModelCostGrid(items: [unknown], fillFirstRow: false).slotCount, 1)
        let latest = Array(DashboardModelCostOrder.policy.groups[0].models.prefix(8)).map { item($0, tokens: 55_714_167) }
        // Measure the production grid, not just its slot policy: a two-column
        // regression doubles the height and must fail even with passing counts.
        for rows in [[], [unknown], Array(latest.prefix(2)), Array(latest.prefix(3)), Array(latest.prefix(4)), latest] {
            let host = NSHostingView(rootView: DashboardModelCostGrid(items: rows, fillFirstRow: true).frame(width: 840))
            XCTAssertEqual(host.fittingSize.width, 840, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, rows.count > 4 ? 67 : 30, accuracy: 0.5)
        }
        let view = VStack(spacing: 10) {
            DashboardModelCostGrid(items: latest, fillFirstRow: true, latest: true)
            DashboardModelCostGrid(items: [unknown], fillFirstRow: true)
            DashboardModelCostGrid(items: [item("codex|gpt-6-astra")], fillFirstRow: true)
        }.frame(width: 840).padding(12).background(Color.white)
        for width: CGFloat in [204, 220, 300] {
            let host = NSHostingView(rootView: DashboardModelCostChip(item: unknown, color: .gray).frame(width: width))
            XCTAssertEqual(host.fittingSize.height, 30, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
        }
        if let output = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light)); renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("model-order-full-row.png"))
        }
    }
}
