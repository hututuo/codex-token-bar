import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class ModelRatePresentationTests: XCTestCase {
    func testCurrentContributionsAggregateSessionsAndKeepUnknownTokens() {
        var curve = ThroughputCurve()
        curve.sessions["a"] = .init(model: "gpt-6-astra", display: 20)
        curve.sessions["b"] = .init(model: "gpt-6-astra", display: 20)
        curve.sessions["c"] = .init(model: "gpt-6.1-sol", display: 50)
        curve.sessions["d"] = .init(model: "", display: 10)
        curve.sessions["idle"] = .init(model: "gpt-6-luna", display: 0)
        XCTAssertEqual(curve.total, 100)
        XCTAssertEqual(curve.modelRates, [.init(model: "gpt-6-astra", tokensPerSecond: 40), .init(model: "gpt-6.1-sol", tokensPerSecond: 50), .init(model: "unknown", tokensPerSecond: 10)])
        curve.consume(.init(kind: "abort", timestamp: 100, turnID: ""), thread: "a", now: 100)
        XCTAssertEqual(curve.total, 80)
        XCTAssertEqual(curve.modelRates.first?.tokensPerSecond, 20)
    }
    func testAliasesMergeAndHardColorBoundaryMatchesFortySixtyContribution() {
        let rates: [ModelRateContribution] = [.init(model: "gpt6astra", tokensPerSecond: 10), .init(model: "gpt-6-astra", tokensPerSecond: 30), .init(model: "gpt-6.1-sol", tokensPerSecond: 60), .init(model: "invalid", tokensPerSecond: .nan)]
        let slices = ModelRatePresentation.slices(rates)
        XCTAssertEqual(slices.map(\.model), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(slices.map(\.share), [0.4, 0.6])
        XCTAssertEqual(ModelRatePresentation.stops(rates).map(\.location), [0, 0.4, 0.4, 1])
        XCTAssertEqual(ModelUsagePresentation.colorHex(for: "gpt6astra"), "#36ad77")
        XCTAssertEqual(ModelUsagePresentation.colorHex(for: "未来-model-Ω"), "#9b9b81")
        XCTAssertEqual(ModelUsagePresentation.colorHex(for: "codex-auto-review@luna"), ModelUsagePresentation.colorHex(for: "gpt-5.6-luna"))
    }
    @MainActor
    func testProductionSegmentFillUsesTheSameColorsAsUsageAndHasRoundedEnds() throws {
        let rates: [ModelRateContribution] = [.init(model: "gpt-6-astra", tokensPerSecond: 40), .init(model: "gpt-6.1-sol", tokensPerSecond: 60)]
        let view = SmoothRateFillLayerView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        view.update(fraction: 1, minimumFraction: 0, colors: [], startPoint: .leading, endPoint: .trailing, animationDuration: 0, animated: false, modelRates: rates)
        let layer = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
        XCTAssertEqual(layer.locations?.map(\.doubleValue), [0, 0.4, 0.4, 1])
        XCTAssertEqual(layer.cornerRadius, 5)
        let colors = try XCTUnwrap(layer.colors as? [CGColor])
        for (index, model) in ["gpt-6-astra", "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-sol"].enumerated() {
            let expected = NSColor(ModelUsagePresentation.color(for: model)).usingColorSpace(.deviceRGB)!
            let actual = NSColor(cgColor: colors[index])!.usingColorSpace(.deviceRGB)!
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        }
        // A ratio change at unchanged total must repaint even without a width change.
        view.update(fraction: 1, minimumFraction: 0, colors: [], startPoint: .leading, endPoint: .trailing, animationDuration: 0, animated: false, modelRates: [.init(model: "gpt-6-astra", tokensPerSecond: 60), .init(model: "gpt-6.1-sol", tokensPerSecond: 40)])
        XCTAssertEqual(layer.locations?.map(\.doubleValue), [0, 0.6, 0.6, 1])
    }
    @MainActor
    func testWidthOnlyRefreshDoesNotReapplyGradientAndRatioChangesStillDo() throws {
        let view = SmoothRateFillLayerView(frame: .init(x: 0, y: 0, width: 300, height: 10))
        func update(_ width: Double, _ astra: Double = 40) {
            view.update(fraction: width, minimumFraction: 0, colors: [], startPoint: .leading, endPoint: .trailing,
                animationDuration: 0.2, animated: true,
                modelRates: [.init(model: "gpt-6-astra", tokensPerSecond: astra), .init(model: "gpt-6.1-sol", tokensPerSecond: 100 - astra)])
        }
        update(0.5)
        let first = view.styleApplicationCount
        for n in 1...50 { update(Double(n) / 100) }
        XCTAssertEqual(view.styleApplicationCount, first)
        update(0.5, 60)
        XCTAssertEqual(view.styleApplicationCount, first + 1)
        let gradient = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
        XCTAssertEqual(gradient.locations?.map(\.doubleValue), [0, 0.6, 0.6, 1])
        XCTAssertNil(gradient.animation(forKey: "smoothRateFillWidth"), "Detached views should not create animations")
    }
    @MainActor
    func testNativeModelRateAndGuidePreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CODEX_MODEL_RATE_PREVIEW"] else { throw XCTSkip("Opt-in component screenshots") }
        let rates: [ModelRateContribution] = [.init(model: "gpt-6-astra", tokensPerSecond: 30), .init(model: "gpt-6.1-sol", tokensPerSecond: 40), .init(model: "gpt-6-luna", tokensPerSecond: 30)]
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
                Text("正式原生组件 · 示例数据：总速度 100 tok/s，Astra 30 / Sol 40 / Luna 30").font(.system(size: 13, weight: .semibold))
                TokenDisplayRateBar(rate: 100, usageStatus: nil, modelRates: rates).frame(height: 30)
                HStack(spacing: 18) {
                    ForEach(ModelRatePresentation.slices(rates)) { slice in
                        HStack(spacing: 5) { Circle().fill(slice.color).frame(width: 8, height: 8); Text("\(ModelUsagePresentation.label(for: slice.model)) \(Int(slice.share * 100))%") }
                    }
                }.font(.system(size: 12))
                RecentChartInteractionGuide()
            }.padding(24).frame(width: 900, height: 330, alignment: .topLeading).background(AppTheme.pageBackground).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("native-model-rate-guide-\(name).png"))
            window.orderOut(nil)
        }
    }

}
