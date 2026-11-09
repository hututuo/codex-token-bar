import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class LiveModelRateSnapshotTests: XCTestCase {
    struct Fixture: Decodable {
        var sources: [ModelRateSource]
        var total: Double
        var modelOrder: [String]
        var clientOrder: [String]
        var rates: [Double]
        var modelSlices: [ModelRateContribution]
        var clientSlices: [ModelRateContribution]
    }
    func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/live-model-rates.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    func testSharedFixtureRingRowsTotalsSourceIdentityAndPaletteGrouping() throws {
        let fixture = try fixture()
        for mode in ActivitySpeedDisplayMode.allCases {
            for grouping in SpeedColorGrouping.allCases {
                let value = ModelRatePresentation.snapshot(sources: fixture.sources, enabled: true, mode: mode, grouping: grouping)
                XCTAssertEqual(value.total, fixture.total)
                XCTAssertEqual(value.rows.map(\.id), grouping == .model ? fixture.modelOrder : fixture.clientOrder)
                XCTAssertEqual(value.rows.map(\.tokensPerSecond), fixture.rates)
                XCTAssertEqual(value.rows.map(\.barFraction), [0.5, 0.75, 1, 0.25])
                XCTAssertEqual(value.rows.map(\.share), [0.2, 0.3, 0.4, 0.1])
                XCTAssertEqual(value.modelRates, fixture.modelSlices)
                XCTAssertEqual(value.colorRates, grouping == .model ? fixture.modelSlices : fixture.clientSlices)
                XCTAssertEqual(ModelRatePresentation.slices(value.colorRates).reduce(0) { $0 + $1.tokensPerSecond }, value.total)
                XCTAssertEqual(value.rows.filter { $0.model == "claude-sonnet-4-6" }.count, 2)
                XCTAssertTrue(value.sourceKey.contains("home-a:7"))
                XCTAssertFalse(value.rows.contains { $0.client == "gemini" })
                let disabled = ModelRatePresentation.snapshot(sources: fixture.sources, enabled: false, mode: mode, grouping: grouping)
                XCTAssertFalse(disabled.available); XCTAssertEqual(disabled.total, 0); XCTAssertTrue(disabled.rows.isEmpty)
                var changed = fixture.sources
                changed[0].sourceKey = "home-b:8"; changed[0].available = false
                let switched = ModelRatePresentation.snapshot(sources: changed, enabled: true, mode: mode, grouping: grouping)
                XCTAssertNotEqual(switched.sourceKey, value.sourceKey)
                XCTAssertEqual(switched.total, 50)
                XCTAssertFalse(switched.rows.contains { $0.client == "codex" })
            }
        }
    }
    func testNormalizationPreservesResidualAndRejectsNonfiniteNegativeAndOverflow() {
        XCTAssertEqual(ModelRatePresentation.normalized([], total: 50), [.init(model: "unknown", tokensPerSecond: 50)])
        XCTAssertEqual(ModelRatePresentation.normalized([.init(model: "m", tokensPerSecond: 80)], total: 20), [.init(model: "m", tokensPerSecond: 20)])
        for value in [Double.nan, .infinity, -1, 0] {
            XCTAssertTrue(ModelRatePresentation.normalized([.init(model: "m", tokensPerSecond: value)]).isEmpty)
            XCTAssertTrue(ModelRatePresentation.normalized([.init(model: "m", tokensPerSecond: 50)], total: value).isEmpty)
        }
        XCTAssertTrue(ModelRatePresentation.normalized([.init(model: "m", tokensPerSecond: .greatestFiniteMagnitude), .init(model: "m", tokensPerSecond: .greatestFiniteMagnitude)]).isEmpty)
    }
    @MainActor func testProductionBarsFitSidebarAndFollowColorOverrides() throws {
        let fixture = try fixture()
        let value = ModelRatePresentation.snapshot(sources: fixture.sources, enabled: true, mode: .bar, grouping: .client)
        let previous = SpeedDisplayPreferences.shared.colors
        defer { SpeedColorOverrides.shared.replace(previous) }
        SpeedColorOverrides.shared.replace(["client:codex": "#abcdef"])
        XCTAssertEqual(ModelUsagePresentation.colorHex(for: try XCTUnwrap(value.rows.last).colorKey), "#abcdef")
        for width: CGFloat in [360, 400, 460] {
            let host = NSHostingView(rootView: LiveModelRateBars(snapshot: value).frame(width: width))
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
            XCTAssertLessThan(host.fittingSize.height, 240)
            XCTAssertGreaterThan(host.fittingSize.height, 120)
        }
    }
}
