import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardModelCostOrderTests: XCTestCase {
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
            "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5",
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"
        ])
        XCTAssertFalse(DashboardModelCostOrder.policy.groups.contains { $0.id == "fable" })
        XCTAssertFalse(DashboardModelCostOrder.groups([item("codex|gpt-6-sol")]).contains { $0.id == "latest" })
    }
    @MainActor
    func testShortPeriodFillsTwoSlotsAndUnknownNameFitsSingleRow() throws {
        let unknown = item("unknown-models", tokens: 13_662_755)
        XCTAssertEqual(DashboardModelCostGrid(items: [unknown], fillFirstRow: true).slotCount, 2)
        XCTAssertEqual(DashboardModelCostGrid(items: [], fillFirstRow: true).slotCount, 2)
        XCTAssertEqual(DashboardModelCostGrid(items: [unknown], fillFirstRow: false).slotCount, 1)
        let view = VStack(spacing: 10) {
            DashboardModelCostGrid(items: [unknown], fillFirstRow: true)
            DashboardModelCostGrid(items: [item("codex|gpt-6-astra")], fillFirstRow: true)
        }.frame(width: 620).padding(12).background(Color.white)
        for width: CGFloat in [300, 360, 440] {
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
