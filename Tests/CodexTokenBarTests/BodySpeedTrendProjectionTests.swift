import AppKit
import XCTest
import SwiftUI
@testable import CodexTokenBar

final class BodySpeedTrendProjectionTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func point(_ model: String, _ offset: Int64, _ speed: Double = 50) -> BodySpeedTrendPoint {
        .init(bucketStart: now + offset, model: model, outputTokens: 500,
              durationSeconds: 10, sampleCount: 6, tokensPerSecond: speed, bucketEnd: now + offset + 300,
              lowerQuartile: speed - 5, median: speed, upperQuartile: speed + 5, bucketCount: 3, isPartial: false)
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
        XCTAssertEqual(Set(all.visiblePoints.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(all.visiblePoints.count, rows.count)
    }
    func testExplicitModelPersistsAndMissingModelFallsBack() {
        let rows = [point("sol", -300), point("luna", -300)]
        XCTAssertEqual(BodySpeedTrendProjection(input: input(rows), selectedModel: "sol").focusModel, "sol")
        XCTAssertEqual(BodySpeedTrendProjection(input: input(rows), selectedModel: "old").focusModel, "luna")
    }
    func testEmptyIntervalsNeverSelectTheNearestMeasuredDistribution() {
        let rows = [point("sol", -1200), point("sol", -300)]
        let result = BodySpeedTrendProjection(input: input(rows), selectedModel: "sol")
        XCTAssertTrue(result.selected(at: Date(timeIntervalSince1970: Double(now - 600))).isEmpty)
        XCTAssertEqual(result.selected(at: Date(timeIntervalSince1970: Double(now - 100))).first?.id, rows.last?.id)
    }
    func testLegacyMeanPointsAreNotDisplayedAsDistributions() {
        var legacy = point("sol", -300)
        legacy.median = nil
        let result = BodySpeedTrendProjection(input: input([legacy]), selectedModel: nil)
        XCTAssertTrue(result.visiblePoints.isEmpty)
    }
    func testWindowFilteringBoundsAndFirstLastDoNotDependOnInputOrder() {
        let rows = [point("sol", -300, 80), point("sol", -90000), point("sol", -600, 40), point("sol", 300)]
        let result = BodySpeedTrendProjection(input: input(rows), selectedModel: "sol")
        XCTAssertEqual(result.visiblePoints.count, 2)
        XCTAssertEqual(result.first?.tokensPerSecond, 40)
        XCTAssertEqual(result.last?.tokensPerSecond, 80)
        XCTAssertEqual(result.yBounds, 27.5...92.5)
    }
    func testEmptyAndChangedInput() {
        let empty = input([])
        XCTAssertEqual(empty, input([]))
        let result = BodySpeedTrendProjection(input: empty, selectedModel: nil)
        XCTAssertTrue(result.visiblePoints.isEmpty)
        XCTAssertEqual(result.yBounds, 0...13)
        var changed = empty
        changed.points = [point("sol", -300)]
        XCTAssertNotEqual(empty, changed)
        changed = empty; changed.error = "read failed"; XCTAssertNotEqual(empty, changed)
        changed = empty; changed.minute += 1; XCTAssertNotEqual(empty, changed)
        changed = empty; changed.windowSeconds = 604800; XCTAssertNotEqual(empty, changed)
    }
    func testResetMarkersUseAcceptedObservedDropsAndPreservePreviousObservationBounds() {
        let date = Date(timeIntervalSince1970: Double(now))
        let observations = [
            QuotaCycleObservation(at: date.addingTimeInterval(-7200), usedPercent: 70, resetsAt: date.addingTimeInterval(10000)),
            QuotaCycleObservation(at: date.addingTimeInterval(-3600), usedPercent: 0, resetsAt: date.addingTimeInterval(10000)),
            QuotaCycleObservation(at: date, usedPercent: 1, resetsAt: date.addingTimeInterval(20000))
        ]
        let projection = QuotaActualCycleProjector.projectWithDiagnostics(observations, now: date)
        var history = QuotaHistorySnapshot.empty
        history.actualCycles = projection.cycles; history.cycleDiagnostics = projection.diagnostics
        XCTAssertEqual(BodySpeedResetMarker.from(history), [.init(observedAt: observations[1].at, previousAt: observations[0].at)])
        history.isStale = true
        XCTAssertTrue(BodySpeedResetMarker.from(history).isEmpty)
    }
    func testWithdrawnResetAndChangedScheduleNeverCreateMarkers() {
        let date = Date(timeIntervalSince1970: Double(now))
        let observations = [
            QuotaCycleObservation(at: date.addingTimeInterval(-7200), usedPercent: 70, resetsAt: date),
            QuotaCycleObservation(at: date.addingTimeInterval(-3600), usedPercent: 0, resetsAt: date),
            QuotaCycleObservation(at: date, usedPercent: 70, resetsAt: date.addingTimeInterval(20000))
        ]
        let projection = QuotaActualCycleProjector.projectWithDiagnostics(observations, now: date, consumption: { _, _ in .absent })
        var history = QuotaHistorySnapshot.empty
        history.actualCycles = projection.cycles; history.cycleDiagnostics = projection.diagnostics
        XCTAssertTrue(BodySpeedResetMarker.from(history).isEmpty)
    }
    @MainActor
    func testOpenSettingsPreviewStillReceivesLivePublications() {
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        var renders = 0
        let host = NSHostingView(rootView: DashboardLivePreviewScope(monitor: monitor) { observed in
            let _ = { renders += 1 }()
            Text(observed.totalSnapshot.status)
        })
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() {
            let until = Date().addingTimeInterval(0.12)
            while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let initial = renders
        XCTAssertGreaterThan(initial, 0)
        monitor.objectWillChange.send()
        settle()
        XCTAssertGreaterThan(renders, initial, "Moving observation out of DashboardView must preserve live settings previews")
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
