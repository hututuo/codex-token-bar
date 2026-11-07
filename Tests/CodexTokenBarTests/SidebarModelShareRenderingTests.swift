import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SidebarModelShareRenderingTests: XCTestCase {
    @MainActor func testStaticAndMorphUseTheSameRenderedModelBoundaries() throws {
        for fractions in [[0.25, 0.75], [0.01, 0.24, 0.75], [1.0], []] {
            let colors: [Color] = [.red, .green, .blue]
            let items = fractions.enumerated().map { index, share in
                FloatingTodayModelUsageItem(id: "model-\(index)", label: "Model \(index)", tokens: Int(share * 100),
                    share: share, costUSD: nil, usesIndependentQuota: false, referenceCostUSD: nil, color: colors[index])
            }
            var offset = 0.0
            let segments = items.map { item in
                let start = offset; offset += item.share
                return ClientQuotaMorphColorSegment(id: item.id, start: start, end: offset, color: NSColor(item.color))
            }
            let route = ClientQuotaMorphRoute(id: "models", ring: CGRect(x: 0, y: 0, width: 52, height: 4),
                track: CGRect(x: 0, y: 0, width: 4, height: 24), half: 0, fraction: 1, color: .gray,
                segments: segments, expandedTrackOpacity: 0.12, shape: .strip)
            for vertical in [false, true] {
                let size = vertical ? route.track.size : route.ring.size
                let renderer = ImageRenderer(content: SidebarModelShareStrip(items: items, vertical: vertical)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
                renderer.scale = 4
                let staticImage = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let view = MatchedStrokeMorphView(frame: CGRect(origin: .zero, size: size))
                view.update(expanded: vertical, enabled: true, participantCount: 1) { ClientQuotaMorphGeometry.strokes([route]) }
                view.update(expanded: !vertical, enabled: true, participantCount: 1) { ClientQuotaMorphGeometry.strokes([route]) }
                defer { view.clear() }
                let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 4), height: Int(size.height * 4),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                // Bitmap contexts are bottom-up; both production views use a
                // top-down coordinate system. Compare the same physical row.
                context.translateBy(x: 0, y: size.height * 4)
                context.scaleBy(x: 4, y: -4)
                try XCTUnwrap(view.layer).render(in: context)
                let morphImage = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                let length = Int((vertical ? size.height : size.width) * 4)
                for index in 2..<(length - 2) {
                    let x = vertical ? 8 : index, y = vertical ? index : 8
                    let actual = try XCTUnwrap(staticImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let animated = try XCTUnwrap(morphImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    func dominant(_ color: NSColor) -> Int {
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        return channels.firstIndex(of: channels.max()!)!
                    }
                    XCTAssertEqual(dominant(actual), dominant(animated), "\(fractions), vertical=\(vertical), pixel=\(index): transition handoff changed the model")
                    if fractions.isEmpty {
                        XCTAssertEqual(actual.alphaComponent, animated.alphaComponent, accuracy: 1.0 / 255,
                            "Empty tracks must keep the same brightness at the handoff")
                    }
                }
            }
        }
    }

    @MainActor func testStripMaskSurvivesImmediateReversalAndReleasesOriginals() throws {
        let registry = MatchedStrokeMorphRegistry(), a = NSView(), b = NSView()
        registry.register(UUID(), view: a, ids: ["models"]); registry.register(UUID(), view: b, ids: ["models"])
        let view = MatchedStrokeMorphView()
        let route = ClientQuotaMorphRoute(id: "models", ring: CGRect(x: 10, y: 20, width: 52, height: 4),
            track: CGRect(x: 70, y: 30, width: 4, height: 24), half: 0, fraction: 1, color: .gray,
            segments: [.init(id: "a", start: 0, end: 0.25, color: .red), .init(id: "b", start: 0.25, end: 1, color: .blue)], shape: .strip)
        for expanded in [true, false, true] {
            view.update(expanded: expanded, enabled: true, participantCount: 1, registry: registry) { ClientQuotaMorphGeometry.strokes([route]) }
        }
        XCTAssertEqual(registry.coveredViewCount, 2)
        for layer in view.layer?.sublayers ?? [] {
            let shape = try XCTUnwrap(layer as? CAShapeLayer)
            XCTAssertEqual(shape.lineCap, .butt)
            let mask = try XCTUnwrap(shape.mask as? CAShapeLayer)
            XCTAssertEqual(mask.lineCap, .round)
            XCTAssertNotNil(mask.animation(forKey: "matched-clip"))
        }
        view.clear()
        XCTAssertEqual(registry.coveredViewCount, 0)
    }
}
