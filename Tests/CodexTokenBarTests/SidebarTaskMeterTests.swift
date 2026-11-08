import AppKit
import XCTest
@testable import CodexTokenBar

final class SidebarTaskMeterTests: XCTestCase {
    private func summary(_ main: Int, _ children: Int, _ rows: [RunningThreadModelBreakdown],
                         freshness: RunningThreadFreshness = .fresh) -> RunningThreadSummary {
        .init(main: main, subagents: children, mainModels: rows, updatedAt: nil, freshness: freshness)
    }

    func testCellsGrowByAgentCountAndKeepModelColors() {
        let rows: [RunningThreadModelBreakdown] = [.init(model: "gpt-6-luna", reasoningEffort: "max", count: 2),
            .init(model: "gpt-6-astra", reasoningEffort: "max", count: 1)]
        let meter = SidebarTaskMeterPresentation(summary: summary(1, 2, rows))
        XCTAssertEqual(meter.cells, ["gpt-6-astra", "gpt-6-luna", "gpt-6-luna"] + Array(repeating: nil, count: 7))
        XCTAssertEqual(meter.color(at: 0), ModelUsagePresentation.color(for: "gpt-6-astra"))
        XCTAssertEqual(meter.color(at: 1), ModelUsagePresentation.color(for: "gpt-6-luna"))
        XCTAssertEqual(meter.cells, SidebarTaskMeterPresentation(summary: summary(1, 2, rows.reversed())).cells)
        XCTAssertTrue(meter.label.contains("每格 1 个"))
    }

    func testZeroUnknownOverflowAndStaleAreDistinct() {
        XCTAssertEqual(SidebarTaskMeterPresentation(summary: summary(0, 0, [])).cells, Array(repeating: nil, count: 10))
        let partial = SidebarTaskMeterPresentation(summary: summary(1, 2, [.init(model: "gpt-6-luna", reasoningEffort: nil, count: 1)]))
        XCTAssertEqual(Array(partial.cells.prefix(4)), ["gpt-6-luna", "unknown", "unknown", nil])
        let overflow = SidebarTaskMeterPresentation(summary: summary(2, 12, [.init(model: "gpt-6-luna", reasoningEffort: nil, count: 14)]))
        XCTAssertEqual(overflow.cells.compactMap { $0 }.count, 10)
        XCTAssertTrue(overflow.label.contains("14 个")); XCTAssertTrue(overflow.label.contains("超过 10"))
        XCTAssertEqual(SidebarTaskMeterPresentation(summary: summary(3, 4, [], freshness: .unavailable)).cells, Array(repeating: nil, count: 10))
        let stale = SidebarTaskMeterPresentation(summary: summary(3, 0, [], freshness: .stale))
        XCTAssertEqual(stale.cells.compactMap { $0 }.count, 3)
        XCTAssertTrue(stale.label.contains("已过期"))
    }

    func testMorphRetainsTenSeparateCellsAndBottomToTopOrder() throws {
        let meter = SidebarTaskMeterPresentation(summary: summary(1, 2, [.init(model: "gpt-6-luna", reasoningEffort: nil, count: 3)]))
        let route = ClientQuotaMorphRoute(id: "tasks", ring: CGRect(x: 0, y: 0, width: 49, height: 49),
            track: CGRect(x: 1, y: 100, width: 4, height: 46), half: 0, fraction: 1, color: .gray,
            segments: meter.morphSegments, shape: .taskCells)
        let strokes = ClientQuotaMorphGeometry.strokes([route])
        XCTAssertEqual(strokes.count, 10)
        for index in strokes.indices {
            let stroke = strokes[index]
            XCTAssertEqual(stroke.lineCap, .butt)
            XCTAssertEqual(stroke.color, NSColor(meter.color(at: index)))
            XCTAssertEqual(stroke.expanded.points.count, stroke.collapsed.points.count)
            let bottom = try XCTUnwrap(stroke.collapsed.points.first).y, top = try XCTUnwrap(stroke.collapsed.points.last).y
            XCTAssertEqual(bottom - top, index == 0 || index == 9 ? 4.3 : 4, accuracy: 0.0001)
            if index > 0 { XCTAssertEqual(try XCTUnwrap(strokes[index - 1].collapsed.points.last).y - bottom, 0.6, accuracy: 0.0001) }
            if index == 0 || index == 9 {
                let clip = try XCTUnwrap(stroke.collapsed.clipPoints)
                XCTAssertEqual(clip.count, stroke.expanded.clipPoints?.count)
                XCTAssertEqual(index == 0 ? clip.first!.y + 2 : clip.last!.y - 2, index == 0 ? 146 : 100, accuracy: 0.0001)
            } else { XCTAssertNil(stroke.collapsed.clipPoints) }
        }
        XCTAssertEqual(strokes.first?.collapsed.points.first?.y, 146)
        XCTAssertEqual(strokes.last?.collapsed.points.last?.y, 100)
    }
}
