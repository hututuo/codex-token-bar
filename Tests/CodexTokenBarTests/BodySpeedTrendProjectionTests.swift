import AppKit
import XCTest
@testable import CodexTokenBar

final class BodySpeedTrendProjectionTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func point(_ model: String, _ offset: Int64, _ speed: Double = 50) -> BodySpeedTrendPoint {
        .init(bucketStart: now + offset, model: model, outputTokens: 500,
              durationSeconds: 10, sampleCount: 2, tokensPerSecond: speed)
    }
    private func input(_ points: [BodySpeedTrendPoint], days: Int = 1) -> BodySpeedTrendInput {
        .init(points: points, days: days, windowSeconds: days * 86400,
              preferredModels: ["luna", "sol"], minute: now / 60, error: nil)
    }
    func testPreferredModelAndExplicitAllSelectionKeepTheSameNumericPoints() {
        let rows = [point("sol", -600, 35), point("luna", -300, 145), point("sol", -300, 40)]
        let preferred = BodySpeedTrendProjection(input: input(rows), selectedModel: nil)
        XCTAssertEqual(preferred.models, ["luna", "sol"])
        XCTAssertEqual(preferred.focusModel, "luna")
        XCTAssertEqual(preferred.visiblePoints, [rows[1]])
        let all = BodySpeedTrendProjection(input: input(rows), selectedModel: "*")
        XCTAssertNil(all.focusModel)
        XCTAssertEqual(all.visiblePoints, rows)
        XCTAssertEqual(all.entries.count, rows.count)
    }
    func testExplicitModelPersistsAndMissingModelFallsBack() {
        let rows = [point("sol", -300), point("luna", -300)]
        XCTAssertEqual(BodySpeedTrendProjection(input: input(rows), selectedModel: "sol").focusModel, "sol")
        XCTAssertEqual(BodySpeedTrendProjection(input: input(rows), selectedModel: "old").focusModel, "luna")
    }
    func testGapsRemainDisconnectedAtEachAggregationWidth() {
        for (days, width) in [(1, Int64(300)), (7, 1800), (30, 7200)] {
            let rows = [point("sol", -4 * width), point("sol", -3 * width), point("sol", -width)]
            let result = BodySpeedTrendProjection(input: input(rows, days: days), selectedModel: "sol")
            XCTAssertEqual(result.entries.map(\.segment), ["sol/0", "sol/0", "sol/1"])
        }
    }
    func testWindowFilteringBoundsAndFirstLastDoNotDependOnInputOrder() {
        let rows = [point("sol", -300, 80), point("sol", -90000), point("sol", -600, 40), point("sol", 300)]
        let result = BodySpeedTrendProjection(input: input(rows), selectedModel: "sol")
        XCTAssertEqual(result.visiblePoints.count, 2)
        XCTAssertEqual(result.first?.tokensPerSecond, 40)
        XCTAssertEqual(result.last?.tokensPerSecond, 80)
        XCTAssertEqual(result.yBounds, 32...88)
    }
    func testEmptyAndChangedInput() {
        let empty = input([])
        XCTAssertEqual(empty, input([]))
        let result = BodySpeedTrendProjection(input: empty, selectedModel: nil)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.yBounds, 0...15)
        var changed = empty
        changed.points = [point("sol", -300)]
        XCTAssertNotEqual(empty, changed)
        changed = empty; changed.error = "read failed"; XCTAssertNotEqual(empty, changed)
        changed = empty; changed.minute += 1; XCTAssertNotEqual(empty, changed)
        changed = empty; changed.windowSeconds = 604800; XCTAssertNotEqual(empty, changed)
    }
    @MainActor
    func testRevealMovesCanvasWithoutResizingItsHostingTree() {
        for edge in QuotaSidebarEdge.allCases {
            let host = SizeCountingView(frame: .zero)
            let canvas = QuotaSidebarCanvasView(host: host, edge: edge)
            let initial = host.resizeCount
            for index in 0...60 {
                let fraction = Double(index) / 60
                canvas.setFrameSize(.init(width: 16 + 72 * fraction, height: 192 + 400 * fraction))
                canvas.layout()
            }
            XCTAssertEqual(host.resizeCount, initial, "Clipping animation must only move the fixed-size SwiftUI host")
            XCTAssertEqual(host.frame.size, .init(width: 88, height: 680))
            canvas.canvasHeight = 800
            XCTAssertEqual(host.resizeCount, initial + 1, "A genuine content-height change still resizes the host")
        }
    }
}

@MainActor
private final class SizeCountingView: NSView {
    var resizeCount = 0
    override func setFrameSize(_ newSize: NSSize) { resizeCount += 1; super.setFrameSize(newSize) }
}
