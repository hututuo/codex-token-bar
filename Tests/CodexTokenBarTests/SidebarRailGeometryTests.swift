import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SidebarRailGeometryTests: XCTestCase {
    @MainActor
    private func render<V: View>(_ view: V, scale: CGFloat = 8) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func save(_ image: NSBitmapImageRep, _ name: String) throws {
        if let folder = ProcessInfo.processInfo.environment["TOKENBAR_DISCOVERY_RENDER_DIR"] {
            let root = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    func testCompactQuotaDotPixelsStayInsideTrackAndMatchMorphEndpoint() throws {
        let padding = 4.0, scale = 8.0
        let item = ClientQuotaItem(id: "codex:7d", client: "codex", window: "7d", remaining: nil,
            resetsAt: nil, source: "fixture", status: "unknown")
        let image = try render(ClientQuotaRailTrack(item: item, height: 46, fillHex: "#ffffff")
            .frame(width: 5, height: 46).padding(padding))
        let track = CGRect(x: padding + 0.5, y: padding + 2.5, width: 4, height: 43.5)
        let outline = CGPath(roundedRect: track, cornerWidth: 2, cornerHeight: 2, transform: nil)
        var dotPixels = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let pixel = try color(image, x, y)
                // The real Codex brand blue, independent of the gray track.
                if pixel.alphaComponent > 0.5 && pixel.blueComponent > pixel.redComponent + 0.2 {
                    dotPixels += 1
                    let point = CGPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)
                    XCTAssertTrue(outline.contains(point), "Brand dot escaped the track at \(point)")
                    XCTAssertGreaterThanOrEqual(point.x, track.minX + 0.5)
                    XCTAssertLessThanOrEqual(point.x, track.maxX - 0.5)
                }
            }
        }
        XCTAssertGreaterThan(dotPixels, 200, "The real marker must actually render")
        let route = ClientQuotaMorphRoute(id: item.id, ring: CGRect(x: 0, y: 0, width: 46, height: 46),
            track: CGRect(x: padding, y: padding, width: 5, height: 46), half: 0, fraction: nil,
            color: .white, marker: CGRect(x: 0, y: 0, width: 5, height: 5), markerColor: .blue)
        let marker = try XCTUnwrap(ClientQuotaMorphGeometry.strokes([route]).first { $0.id == "marker:" + item.id })
        XCTAssertEqual(marker.expanded.width, 5)
        XCTAssertEqual(marker.collapsed.width, 3)
        XCTAssertEqual(marker.collapsed.points.first, CGPoint(x: track.midX, y: track.minY + 2))
        // The circle's entire boundary must fit inside the background capsule.
        for step in 0..<64 {
            let angle = Double(step) / 64 * 2 * Double.pi
            XCTAssertTrue(outline.contains(CGPoint(x: track.midX + cos(angle) * 1.5,
                y: track.minY + 2 + sin(angle) * 1.5)))
        }
        try save(image, "sidebar-quota-dot-contained")
    }

    @MainActor
    func testTaskRailRenderedCapsAndSeparatorsMatchMorphForEmptyPartialFullAndStale() throws {
        let scale = 8, padding = 4.0, size = CGSize(width: 12, height: 54)
        for (total, freshness) in [(0, RunningThreadFreshness.fresh), (4, .fresh), (10, .fresh), (4, .stale)] {
            let summary = RunningThreadSummary(main: total, subagents: 0,
                mainModels: [.init(model: "gpt-6-astra", reasoningEffort: nil, count: total)],
                updatedAt: nil, freshness: freshness)
            let meter = SidebarTaskMeterPresentation(summary: summary)
            let image = try render(SidebarTaskMeter(presentation: meter).frame(width: 4, height: 46).padding(padding))
            let track = CGRect(x: padding, y: padding, width: 4, height: 46)
            let route = ClientQuotaMorphRoute(id: "tasks", ring: CGRect(x: 0, y: 0, width: 46, height: 46),
                track: track, half: 0, fraction: 1, color: .gray, segments: meter.morphSegments, shape: .taskCells)
            let view = MatchedStrokeMorphView(frame: CGRect(origin: .zero, size: size))
            view.update(expanded: true, enabled: true, participantCount: 1) { ClientQuotaMorphGeometry.strokes([route]) }
            view.update(expanded: false, enabled: true, participantCount: 1) { ClientQuotaMorphGeometry.strokes([route]) }
            defer { view.clear() }
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: size.height * Double(scale))
            context.scaleBy(x: Double(scale), y: -Double(scale))
            try XCTUnwrap(view.layer).render(in: context)
            let animated = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            for bitmap in [image, animated] {
                // Flat heads would paint these four corner pixels. A real
                // semicircle still paints the center at both ends, including gray.
                for y in [33, 398] {
                    XCTAssertLessThan(try color(bitmap, 33, y).alphaComponent, 0.02)
                    XCTAssertLessThan(try color(bitmap, 62, y).alphaComponent, 0.02)
                    XCTAssertGreaterThan(try color(bitmap, 48, y).alphaComponent, 0.08)
                }
                for gap in 1..<10 {
                    let y = Int((padding + 46 * Double(gap) / 10) * Double(scale))
                    XCTAssertLessThan(try color(bitmap, 48, y).alphaComponent, 0.02, "Internal gap \(gap) disappeared")
                }
                for cell in 0..<10 {
                    let y = Int((padding + 46 * (Double(cell) + 0.5) / 10) * Double(scale))
                    XCTAssertGreaterThan(try color(bitmap, 48, y).alphaComponent, 0.08, "Cell \(cell) disappeared")
                }
            }
            // Compare the actual compositor handoff away from antialiased edges.
            for y in 34..<398 where (y - 32) % 37 > 3 {
                let a = try color(image, 48, y), b = try color(animated, 48, y)
                XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.08)
                if min(a.alphaComponent, b.alphaComponent) > 0.9 {
                    XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.08)
                }
            }
            try save(image, "sidebar-task-caps-\(total)-\(freshness)")
        }
    }

    @MainActor
    func testTaskCapMasksSurviveImmediateReversalAndReleaseParticipants() throws {
        let registry = MatchedStrokeMorphRegistry(), compact = NSView(), expanded = NSView()
        registry.register(UUID(), view: compact, ids: ["tasks"])
        registry.register(UUID(), view: expanded, ids: ["tasks"])
        let meter = SidebarTaskMeterPresentation(summary: .unavailable)
        let route = ClientQuotaMorphRoute(id: "tasks", ring: CGRect(x: 0, y: 0, width: 46, height: 46),
            track: CGRect(x: 6, y: 90, width: 4, height: 46), half: 0, fraction: 1, color: .gray,
            segments: meter.morphSegments, shape: .taskCells)
        let view = MatchedStrokeMorphView()
        for state in [true, false, true] {
            view.update(expanded: state, enabled: true, participantCount: 1, registry: registry) { ClientQuotaMorphGeometry.strokes([route]) }
        }
        XCTAssertEqual(registry.coveredViewCount, 2)
        let layers = (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(layers.count, 10)
        XCTAssertEqual(layers.filter { $0.mask != nil }.count, 2)
        for layer in layers {
            XCTAssertEqual(layer.lineCap, .butt)
            if let mask = layer.mask as? CAShapeLayer {
                XCTAssertEqual(mask.lineCap, .round)
                XCTAssertNotNil(mask.animation(forKey: "matched-clip"))
            }
        }
        view.update(expanded: false, enabled: false, participantCount: 1, registry: registry) { ClientQuotaMorphGeometry.strokes([route]) }
        XCTAssertEqual(registry.coveredViewCount, 0, "Reduced motion restores the static capped meter")
        XCTAssertEqual(view.morphLayerCount, 0)
    }
}
