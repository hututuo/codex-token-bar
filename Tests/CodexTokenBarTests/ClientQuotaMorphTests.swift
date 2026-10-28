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

    func testWholeRingKeepsBothHalvesAndExactlyOneContinuousBarAtEveryQuota() throws {
        let outline = ClientQuotaMorphGeometry.strokes([ClientQuotaMorphRoute(id: "whole", ring: ring, track: track, half: 0, fraction: 1, color: .green)]).filter { $0.id.hasSuffix(":track") }
        XCTAssertEqual(outline.count, 2)
        let ranges = try outline.map { stroke -> ClosedRange<Double> in
            XCTAssertGreaterThan(stroke.collapsed.opacity, 0)
            let ys = stroke.collapsed.points.map(\.y)
            return try XCTUnwrap(ys.min())...XCTUnwrap(ys.max())
        }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertEqual(ranges[0].lowerBound, track.minY + 2, accuracy: 0.001)
        XCTAssertEqual(ranges[0], ranges[1], "Both sides must squeeze onto the same complete bar, without flipping either side")
        XCTAssertEqual(ranges[1].upperBound, track.maxY - 2, accuracy: 0.001)
        for quota in [0.1, 0.49, 0.5, 0.51, 0.72, 1.0] {
            let fills = ClientQuotaMorphGeometry.strokes([ClientQuotaMorphRoute(id: "whole", ring: ring, track: track, half: 0, fraction: quota, color: .green)]).filter { $0.id.hasSuffix(":fill") }
            XCTAssertEqual(fills.count, 2)
            let barFraction = max(0, min(1, (quota * track.height - 4) / (track.height - 4)))
            var lengths = 0.0
            for stroke in fills {
                XCTAssertEqual(stroke.collapsed.opacity, 1, "Neither half may fade away")
                let points = stroke.collapsed.points
                let length = abs(try XCTUnwrap(points.last).y - XCTUnwrap(points.first).y) * (stroke.collapsed.end - stroke.collapsed.start)
                XCTAssertEqual(length, (track.height - 4) * barFraction, accuracy: 0.001)
                lengths = max(lengths, length)
            }
            XCTAssertEqual(lengths, (track.height - 4) * barFraction, accuracy: 0.001, "The merged bar must retain the real quota fraction")
        }
    }

    func testPairedHalfStillMapsItsOwnEntireBarFromBottomToTop() {
        for half in [-1, 1] {
            let fills = ClientQuotaMorphGeometry.strokes([ClientQuotaMorphRoute(id: "paired", ring: ring, track: track, half: half, fraction: 0.62, color: .green)]).filter { $0.id.hasSuffix(":fill") }
            XCTAssertEqual(fills.count, 1)
            XCTAssertEqual(fills[0].collapsed.start, 0)
            XCTAssertEqual(fills[0].collapsed.end, (0.62 * track.height - 4) / (track.height - 4), accuracy: 0.001)
            XCTAssertEqual(fills[0].collapsed.points.first?.y, track.maxY - 2)
            XCTAssertEqual(fills[0].collapsed.points.last?.y, track.minY + 2)
        }
    }

    func testSharedSpeedMorphPreservesEachModelColorAndItsShare() throws {
        let route = ClientQuotaMorphRoute(id: "speed", ring: ring, track: track, half: 0, fraction: 0.9, color: .gray,
            segments: [.init(id: "astra", start: 0, end: 0.4, color: .green), .init(id: "sol", start: 0.4, end: 1, color: .orange)])
        let strokes = ClientQuotaMorphGeometry.strokes([route])
        let totalLength = 0.9 * track.height - 4
        for (id, share, color) in [("astra", 0.4, NSColor.green), ("sol", 0.6, NSColor.orange)] {
            let colored = strokes.filter { $0.id.hasSuffix(":" + id) }
            XCTAssertFalse(colored.isEmpty)
            var length = 0.0
            for stroke in colored {
                XCTAssertEqual(stroke.color, color)
                XCTAssertEqual(stroke.collapsed.opacity, 1)
                length = max(length, abs(try XCTUnwrap(stroke.collapsed.points.last).y - XCTUnwrap(stroke.collapsed.points.first).y) * (stroke.collapsed.end - stroke.collapsed.start))
            }
            XCTAssertEqual(length, totalLength * share, accuracy: 0.001)
        }
    }

    func testWholeCircleSqueezesWithoutChangingPointDirectionOrCrossing() throws {
        for step in 0...100 {
            let p = Double(step) / 100
            let a = ClientQuotaMorphGeometry.points(ring: ring, track: track, half: -2, progress: p)
            let b = ClientQuotaMorphGeometry.points(ring: ring, track: track, half: 2, progress: p)
            let center = ring.midX + (track.midX - ring.midX) * p
            for (left, right) in zip(a, b) {
                XCTAssertLessThanOrEqual(left.x, center + 0.001)
                XCTAssertGreaterThanOrEqual(right.x, center - 0.001)
                XCTAssertEqual(left.y, right.y, accuracy: 0.001, "Both sides compress together; neither may turn over")
            }
            for points in [a, b] {
                for (first, next) in zip(points, points.dropFirst()) { XCTAssertGreaterThanOrEqual(first.y + 0.001, next.y) }
            }
        }
    }

    func testModelUsageStripMatchesEveryColorToTheVerticalBar() throws {
        let source = CGRect(x: 18, y: 100, width: 52, height: 4)
        let route = ClientQuotaMorphRoute(id: "models", ring: source, track: track, half: 0, fraction: 1, color: .gray,
            segments: [.init(id: "astra", start: 0, end: 0.25, color: .green), .init(id: "sol", start: 0.25, end: 1, color: .orange)], shape: .strip)
        let strokes = ClientQuotaMorphGeometry.strokes([route])
        XCTAssertEqual(strokes.count, 3)
        for stroke in strokes {
            XCTAssertEqual(stroke.participantID, "models")
            XCTAssertTrue(stroke.expanded.points.allSatisfy { $0.y == source.midY })
            XCTAssertTrue(stroke.collapsed.points.allSatisfy { $0.x == track.midX })
            XCTAssertEqual(stroke.expanded.start, stroke.collapsed.start)
            XCTAssertEqual(stroke.expanded.end, stroke.collapsed.end)
        }
        let astra = try XCTUnwrap(strokes.first { $0.id == "models:astra" })
        XCTAssertEqual(astra.collapsed.end - astra.collapsed.start, 0.25)
        XCTAssertEqual(astra.color, .green)
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
        XCTAssertEqual(total, ClientQuotaMorphGeometry.openingDuration)
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
        XCTAssertEqual(view.compositingGroupCount, 1, "Both translucent halves must compose once, without doubled seam opacity")
        view.clear()
        XCTAssertEqual(view.compositingGroupCount, 0)
    }

    @MainActor func testWholeRingJoinHasNoDoubleOpacity() throws {
        let view = MatchedStrokeMorphView(frame: CGRect(x: 0, y: 0, width: 88, height: 380))
        let route = ClientQuotaMorphRoute(id: "outline", ring: ring, track: track, half: 0, fraction: nil, color: .green)
        view.update(expanded: true, enabled: true, routes: [route])
        view.update(expanded: false, enabled: true, routes: [route])
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 88, height: 380, bitsPerComponent: 8, bytesPerRow: 88 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try XCTUnwrap(view.layer).render(in: bitmap)
        let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let maxAlpha = stride(from: 3, to: 88 * 380 * 4, by: 4).map { pixels[$0] }.max() ?? 0
        XCTAssertGreaterThan(maxAlpha, 20, "The geometry must actually render")
        XCTAssertLessThanOrEqual(maxAlpha, 33, "12% outline opacity must not double at the join")
        view.clear()
        XCTAssertEqual(view.compositingGroupCount, 0)
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
        defaults.set(["modeltrace", "radar", "credits"], forKey: "quotaSidebarHiddenModules")
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
        // Exercise a live hosting tree: newer SwiftUI versions defer observed
        // state updates for a view that has never been attached to a window.
        let window = NSWindow(contentRect: CGRect(x: 180, y: 100, width: 88, height: 640),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
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
        XCTAssertEqual(overlay.availableRouteCount, 6, "Quota, speed, tasks and model usage share the same morph surface")
        // Hosting can deliver its initial hover while first laying out on a
        // fresh runner. Start this reversal scenario from a settled compact rail.
        controller.dismiss(); settle(0.4)
        XCTAssertFalse(controller.interaction.expanded)
        let started = overlay.animationsStarted
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        controller.enter(); settle(0.08)
        XCTAssertEqual(overlay.animationsStarted, started + (reducedMotion ? 0 : 1))
        XCTAssertEqual(overlay.morphLayerCount, reducedMotion ? 0 : 16)
        XCTAssertEqual(overlay.coveredParticipantViewCount, reducedMotion ? 0 : 16, "Quota dots join quota, speed and task source/target views until handoff; reduced motion uses the native endpoints directly")
        controller.dismiss(); settle(0.08)
        XCTAssertEqual(overlay.animationsStarted, started + (reducedMotion ? 0 : 2))
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
        let routes = fixtures() + [ClientQuotaMorphRoute(id: "models", ring: CGRect(x: 18, y: 296, width: 52, height: 4),
            track: CGRect(x: 6, y: 366, width: 4, height: 24), half: 0, fraction: 1, color: .gray,
            segments: [.init(id: "astra", start: 0, end: 0.4, color: NSColor(clientHex: "#a3d977")),
                       .init(id: "sol", start: 0.4, end: 1, color: NSColor(clientHex: "#df7055"))], shape: .strip)]
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("向内压合 · 原生路径分镜 · 模拟额度与模型占比").font(.system(size: 13)).foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach([0.0, 0.15, 0.35, 0.65, 1.0], id: \.self) { t in
                    VStack(spacing: 6) {
                        Text("\(Int(t * ClientQuotaMorphGeometry.closingDuration * 1000)) ms").font(.system(size: 11)).foregroundStyle(.gray)
                        Canvas { context, _ in
                            let progress = QuotaSidebarMotion.progress(t, expanding: false)
                            let strokes = ClientQuotaMorphGeometry.strokes(routes)
                            let keys = strokes.reduce(into: [String]()) { list, stroke in
                                let key = stroke.opacityGroup ?? stroke.id
                                if !list.contains(key) { list.append(key) }
                            }
                            for key in keys {
                                let members = strokes.filter { ($0.opacityGroup ?? $0.id) == key }
                                context.drawLayer { layer in
                                    if let first = members.first {
                                        layer.opacity = Double(first.expanded.opacity + (first.collapsed.opacity - first.expanded.opacity) * Float(progress))
                                    }
                                    for stroke in members {
                                        let path = Path(MatchedStrokeMorphGeometry.interpolate(stroke.expanded.points, stroke.collapsed.points, progress: progress))
                                        let start = stroke.expanded.start + (stroke.collapsed.start - stroke.expanded.start) * progress
                                        let end = stroke.expanded.end + (stroke.collapsed.end - stroke.expanded.end) * progress
                                        let width = stroke.expanded.width + (stroke.collapsed.width - stroke.expanded.width) * progress
                                        layer.stroke(path.trimmedPath(from: start, to: end), with: .color(Color(nsColor: stroke.color)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                                    }
                                }
                            }
                        }.frame(width: 88, height: 400).background(.black, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }.padding(20).background(Color(white: 0.06)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 470)
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
