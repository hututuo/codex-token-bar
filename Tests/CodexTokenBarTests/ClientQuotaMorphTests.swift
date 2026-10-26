import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class ClientQuotaMorphTests: XCTestCase {
    private let ring = CGRect(x: 21, y: 110, width: 46, height: 46)
    private let track = CGRect(x: 6, y: 250, width: 4, height: 24)

    func testArcIdentityAndExactContinuousBarEndpoint() throws {
        for half in [-2, -1, 0, 1, 2] {
            let start = ClientQuotaMorphGeometry.points(ring: ring, track: track, half: half, progress: 0)
            let end = ClientQuotaMorphGeometry.points(ring: ring, track: track, half: half, progress: 1)
            XCTAssertEqual(start.count, end.count)
            XCTAssertEqual(end.count, 33)
            if half < 0 { XCTAssertTrue(start.allSatisfy { $0.x <= ring.midX + 0.001 }) }
            if half > 0 { XCTAssertTrue(start.allSatisfy { $0.x >= ring.midX - 0.001 }) }
            if half != 0 {
                for pair in zip(start, start.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.0.y + 0.001, pair.1.y, "Convex halves must flatten without curling back") }
            }
            XCTAssertTrue(end.allSatisfy { abs($0.x - track.midX) < 0.001 })
            XCTAssertEqual(try XCTUnwrap(end.first).y, track.maxY - 2, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(end.last).y, track.minY + 2, accuracy: 0.001)
            for step in 0...20 {
                let points = ClientQuotaMorphGeometry.points(ring: ring, track: track, half: half, progress: Double(step) / 20)
                XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                XCTAssertEqual(ClientQuotaMorphGeometry.vertices(ClientQuotaMorphGeometry.path(points))?.count, 33)
            }
        }
    }

    func testCollapseShrinksWidthAndHeightTogetherAndKeepsEitherDockedEdge() {
        let area = CGRect(x: -1440, y: -240, width: 1440, height: 900)
        for edge in [QuotaSidebarEdge.left, .right] {
            let from = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, expandedHeight: 580).rail
            let to = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false, compactHeight: 182).rail
            let half = QuotaSidebarMotion.collapseFrame(from: from, to: to, time: 0.5, edge: edge, area: area, scale: 2)
            XCTAssertLessThan(half.height, from.height)
            XCTAssertGreaterThan(half.height, to.height)
            XCTAssertLessThan(half.width, 30)
            for step in 0...100 {
                let frame = QuotaSidebarMotion.collapseFrame(from: from, to: to, time: Double(step) / 100, edge: edge, area: area, scale: 2)
                XCTAssertTrue(area.contains(frame))
                XCTAssertEqual(edge == .left ? frame.minX : frame.maxX, edge == .left ? area.minX : area.maxX)
                let horizontal = (from.width - frame.width) / (from.width - to.width)
                let vertical = (from.height - frame.height) / (from.height - to.height)
                XCTAssertEqual(horizontal, vertical, accuracy: 0.01, "Both dimensions must use the same progress, allowing pixel rounding")
            }
            XCTAssertEqual(QuotaSidebarMotion.collapseFrame(from: from, to: to, time: 1, edge: edge, area: area, scale: 2), to)
        }
        XCTAssertGreaterThan(QuotaSidebarMotion.progress(0.5, expanding: false), 0.8)
    }

    func testHeightAndStrokeFinishTogetherWithoutAnExtraTail() {
        let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let from = CGRect(x: 0, y: 160, width: 88, height: 580)
        let to = CGRect(x: 0, y: 359, width: 16, height: 182)
        let total = ClientQuotaMorphGeometry.closingDuration
        func height(_ seconds: Double) -> Double {
            QuotaSidebarMotion.collapseFrame(from: from, to: to, time: seconds / total,
                edge: .left, area: area, scale: 2).height
        }
        XCTAssertEqual(total, 0.18)
        XCTAssertEqual(height(total / 2), from.height + (to.height - from.height) * MatchedStrokeMorphTiming.progress(0.5, expanding: false), accuracy: 0.5)
        XCTAssertLessThan(height(total - 0.001) - height(total), 1)
        XCTAssertEqual(height(0), from.height)
        XCTAssertEqual(height(total), to.height)
        XCTAssertEqual(height(total + 0.12), to.height)
    }

    @MainActor func testTransientLayersAreBoundedCancelOnReversalAndDoNoWorkAtRest() {
        let view = MatchedStrokeMorphView(frame: CGRect(x: 0, y: 0, width: 88, height: 640))
        let routes = fixtures()
        view.update(expanded: false, enabled: true, routes: routes)
        XCTAssertEqual(view.morphLayerCount, 0)
        view.update(expanded: true, enabled: true, routes: routes)
        XCTAssertEqual(view.morphLayerCount, 8)
        XCTAssertTrue(view.isAnimating)
        for _ in 0..<100 { view.update(expanded: true, enabled: true, routes: routes) }
        XCTAssertEqual(view.animationsStarted, 1, "Unchanged data/geometry must never restart animations")
        view.update(expanded: false, enabled: true, routes: routes)
        XCTAssertEqual(view.animationsStarted, 2)
        XCTAssertEqual(view.morphLayerCount, 8, "Reversing replaces layers rather than accumulating work")
        view.update(expanded: true, enabled: false, routes: routes)
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(view.morphLayerCount, 0, "Reduced motion cancels immediately")
        view.clear()
        XCTAssertEqual(view.morphLayerCount, 0)
    }

    @MainActor func testUnknownQuotaMorphsOnlyItsTrackWithoutInventingColoredUsage() {
        let view = MatchedStrokeMorphView(frame: CGRect(x: 0, y: 0, width: 88, height: 640))
        let route = ClientQuotaMorphRoute(id: "unknown", ring: ring, track: track, half: 0, fraction: nil, color: .green)
        view.update(expanded: true, enabled: true, routes: [route])
        view.update(expanded: false, enabled: true, routes: [route])
        XCTAssertEqual(view.morphLayerCount, 2, "Unknown quota has two unfilled outline halves only")
        view.clear()
    }

    @MainActor func testAnimationCompletionReleasesLayersAndPreparationCost() {
        let view = MatchedStrokeMorphView(frame: CGRect(x: 0, y: 0, width: 88, height: 640)), routes = fixtures()
        view.update(expanded: true, enabled: true, routes: routes)
        var measurements: [Double] = [], opening: [Double] = [], closing: [Double] = []
        for index in 0..<100 {
            view.update(expanded: index % 2 == 1, enabled: true, routes: routes)
            measurements.append(view.lastPreparationMilliseconds)
            if index % 2 == 1 { opening.append(view.lastPreparationMilliseconds) } else { closing.append(view.lastPreparationMilliseconds) }
        }
        measurements.sort(); opening.sort(); closing.sort()
        print("QUOTA_MORPH_PHASE_PREP_MS openingMedian=\(opening[25]) closingMedian=\(closing[25]) closingP95=\(closing[47])")
        print("QUOTA_MORPH_PREPARE_MS median=\(measurements[50]) p95=\(measurements[95]) layers=\(view.morphLayerCount)")
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(view.morphLayerCount, 0, "Completion must leave no idle animation, layers or timer")
    }

    @MainActor func testOriginalRailResolvesBothHalfArcsToTheirOwnBarAndReverses() throws {
        let suite = "QuotaMorph-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: ClientDisplayScope.key)
        defaults.set(["overview", "speeds", "modeltrace", "tasks", "radar", "credits"], forKey: "quotaSidebarModuleOrder")
        defaults.set(["speeds", "modeltrace", "tasks", "radar", "credits"], forKey: "quotaSidebarHiddenModules")
        let controller = QuotaSidebarController(settings: defaults)
        let root = QuotaSidebarRail(controller: controller,
            store: CodexUsageStore(autoStart: false, continuityDefaults: defaults),
            quota: AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false),
            tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quotaItemsOverride: ClientQuotaProjection.previewItems(includeClaude: true))
            .defaultAppStorage(defaults).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 88, height: 640)
        func settle(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        func morph(_ view: NSView) -> MatchedStrokeMorphView? {
            if let value = view as? MatchedStrokeMorphView { return value }
            return view.subviews.lazy.compactMap(morph).first
        }
        settle(0.1)
        let overlay = try XCTUnwrap(morph(host))
        XCTAssertEqual(overlay.availableRouteCount, 3)
        controller.enter(); settle(0.08)
        XCTAssertEqual(overlay.animationsStarted, 1)
        XCTAssertEqual(overlay.morphLayerCount, 8)
        XCTAssertEqual(overlay.coveredParticipantViewCount, 5, "Both original rings and all three original bars are covered until handoff")
        controller.dismiss(); settle(0.08)
        XCTAssertEqual(overlay.animationsStarted, 2)
        settle(0.5)
        XCTAssertEqual(overlay.morphLayerCount, 0)
        XCTAssertFalse(overlay.isAnimating)
        XCTAssertEqual(overlay.coveredParticipantViewCount, 0)

    }

    @MainActor private func fixtures() -> [ClientQuotaMorphRoute] {
        ClientQuotaProjection.previewItems(includeClaude: true).enumerated().map { index, item in
            ClientQuotaMorphRoute(id: item.id, ring: CGRect(x: 21, y: index == 0 ? 90 : 200, width: 46, height: 46),
                track: CGRect(x: 6, y: 270 + index * 32, width: 4, height: 24), half: index == 0 ? 0 : index == 1 ? -1 : 1,
                fraction: item.remaining.map { $0 / 100 }, color: NSColor(clientHex: item.fill))
        }
    }

    @MainActor func testRenderActualPathStoryboards() throws {
        guard let output = ProcessInfo.processInfo.environment["TOKENBAR_MORPH_RENDER_OUTPUT"] else { return }
        let routes = fixtures()
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("同一原生路径的收起分镜 · 模拟额度").font(.system(size: 13)).foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach([0.0, 0.15, 0.35, 0.65, 1.0], id: \.self) { t in
                    VStack(spacing: 6) {
                        Text("\(Int(t * 180)) ms").font(.system(size: 11)).foregroundStyle(.gray)
                        Canvas { context, _ in
                            let progress = QuotaSidebarMotion.progress(t, expanding: false)
                            for route in routes {
                                for part in ClientQuotaMorphGeometry.parts(half: route.half, fraction: route.fraction) {
                                let points = ClientQuotaMorphGeometry.points(ring: route.ring, track: route.track, half: part.half, progress: progress)
                                let path = Path(ClientQuotaMorphGeometry.path(points))
                                context.stroke(path, with: .color(.white.opacity(0.13)), style: StrokeStyle(lineWidth: 3 + progress, lineCap: .round, lineJoin: .round))
                                context.stroke(path.trimmedPath(from: part.start * (1 - progress), to: part.end + ((route.fraction ?? 0) - part.end) * progress), with: .color(Color(nsColor: route.color)), style: StrokeStyle(lineWidth: 3 + progress, lineCap: .round, lineJoin: .round))
                                }
                            }
                        }.frame(width: 88, height: 380).background(.black, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }.padding(20).background(Color(white: 0.06)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 450)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}

@MainActor private extension MatchedStrokeMorphView {
    func update(expanded: Bool, enabled: Bool, routes: [ClientQuotaMorphRoute]) {
        update(expanded: expanded, enabled: enabled, participantCount: routes.count) { ClientQuotaMorphGeometry.strokes(routes) }
    }
}
