import AppKit
import SwiftUI
import QuartzCore

/// Layout anchors are resolved only on layout/state changes, never on display ticks.
struct ClientQuotaMorphAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

enum ClientQuotaMorphGeometry {
    static let segments = 32
    static let closingDuration = MatchedStrokeMorphTiming.standard.closingDuration
    static let openingDuration = MatchedStrokeMorphTiming.standard.openingDuration

    // Same point count/order at both ends lets Core Animation interpolate paths.
    // A line runs bottom-to-top, preserving the quota fraction as strokeEnd.
    static func points(ring: CGRect, track: CGRect, half: Int, progress: Double) -> [CGPoint] {
        let p = min(1, max(0, progress)), radius = ring.width / 2
        let gap = abs(half) == 2 ? 0.0 : 0.006 * 2 * Double.pi
        let start = half == 0 ? -Double.pi / 2 : (half < 0 ? Double.pi / 2 + gap : Double.pi / 2 - gap)
        let sweep = half == 0 ? 2 * Double.pi : (Double.pi - 2 * gap) * (half < 0 ? 1 : -1)
        return (0...segments).map { index in
            let t = Double(index) / Double(segments), angle = start + sweep * t
            let x = ring.midX + radius * cos(angle), y = ring.midY + radius * sin(angle)
            let bottom = track.maxY - 2, top = track.minY + 2
            // Both sides keep bottom-to-top point order. Squeeze the circle
            // sideways into one line; never turn either side over into a
            // different half of the destination (which looks like wringing).
            let endY = bottom + (top - bottom) * t
            return CGPoint(x: x + (track.midX - x) * p, y: y + (endY - y) * p)
        }
    }

    struct Part {
        let half: Int
        let start: Double
        let end: Double
    }
    static func parts(half: Int, fraction: Double?) -> [Part] {
        let q = min(1, max(0, fraction ?? 0))
        if half == 0 {
            // Both convex sides converge onto the same complete bar. Shared
            // compositing below prevents doubled opacity when they meet.
            return [Part(half: -2, start: 0, end: max(0, q * 2 - 1)),
                    Part(half: 2, start: 1 - min(1, q * 2), end: 1)]
        }
        return [Part(half: half, start: half < 0 ? 0 : 1 - q, end: half < 0 ? q : 1)]
    }

    // Map an interval along a complete ring onto either convex half. The same
    // mapping carries model-colored speed slices without merging their colors.
    static func interval(half: Int, lower: Double, upper: Double, collapsed: Bool) -> (Double, Double) {
        if collapsed && abs(half) == 2 { return (lower, upper) }
        if half == 2 { return (1 - min(1, upper * 2), 1 - min(1, lower * 2)) }
        if half == -2 { return (max(0, lower * 2 - 1), max(0, upper * 2 - 1)) }
        return half > 0 && !collapsed ? (1 - upper, 1 - lower) : (lower, upper)
    }

    static func path(_ points: [CGPoint]) -> CGPath { MatchedStrokeMorphGeometry.path(points) }
    static func vertices(_ path: CGPath?) -> [CGPoint]? { MatchedStrokeMorphGeometry.vertices(path) }
    static func interpolate(_ from: [CGPoint], _ to: [CGPoint], progress: Double) -> CGPath {
        MatchedStrokeMorphGeometry.interpolate(from, to, progress: progress)
    }

    static func strokes(_ routes: [ClientQuotaMorphRoute]) -> [MatchedStrokeMorphRoute] {
        let strokes = routes.flatMap { route -> [MatchedStrokeMorphRoute] in
            if route.shape == .strip { return stripStrokes(route) }
            return parts(half: route.half, fraction: route.fraction).flatMap { part -> [MatchedStrokeMorphRoute] in
                let expandedPoints = points(ring: route.ring, track: route.track, half: part.half, progress: 0)
                let collapsedPoints = points(ring: route.ring, track: route.track, half: part.half, progress: 1)
                let prefix = route.id + ":" + String(part.half)
                var strokes: [MatchedStrokeMorphRoute] = []
                if route.expandedTrackOpacity > 0 || route.collapsedTrackOpacity > 0 {
                    strokes.append(MatchedStrokeMorphRoute(id: prefix + ":track", participantID: route.id,
                        expanded: .init(points: expandedPoints, width: 3, opacity: route.expandedTrackOpacity),
                        collapsed: .init(points: collapsedPoints, width: 4, opacity: route.collapsedTrackOpacity), color: .white,
                        opacityGroup: route.half == 0 ? route.id + ":track" : nil))
                }
                let q = min(1, max(0, route.fraction ?? 0))
                guard q > 0 else { return strokes }
                let barFraction = max(0, min(1, (q * route.track.height - 4) / max(1, route.track.height - 4)))
                let segments = route.segments.isEmpty ? [ClientQuotaMorphColorSegment(id: "fill", start: 0, end: 1, color: route.color)] : route.segments
                for segment in segments {
                    let start = min(1, max(0, segment.start)), end = min(1, max(start, segment.end))
                    let expanded = interval(half: part.half, lower: start * q, upper: end * q, collapsed: false)
                    let collapsed = interval(half: part.half, lower: start * barFraction, upper: end * barFraction, collapsed: true)
                    if !route.segments.isEmpty && expanded.0 == expanded.1 && collapsed.0 == collapsed.1 { continue }
                    strokes.append(MatchedStrokeMorphRoute(id: prefix + ":" + segment.id, participantID: route.id,
                        expanded: .init(points: expandedPoints, start: expanded.0, end: expanded.1, width: 3, opacity: route.fillOpacity),
                        collapsed: .init(points: collapsedPoints, start: collapsed.0, end: collapsed.1, width: 4, opacity: route.fillOpacity), color: segment.color,
                        opacityGroup: route.half == 0 ? route.id + ":" + segment.id : nil))
                }
                return strokes
            }
        }
        let markers: [MatchedStrokeMorphRoute] = routes.compactMap { route in
            guard let marker = route.marker, let color = route.markerColor else { return nil }
            let end = CGPoint(x: route.track.midX, y: route.track.minY + 2.5)
            func dot(_ point: CGPoint) -> [CGPoint] { [point, CGPoint(x: point.x + 0.001, y: point.y)] }
            return .init(id: "marker:" + route.id, participantID: "marker:" + route.id,
                expanded: .init(points: dot(CGPoint(x: marker.midX, y: marker.midY)), width: 5, opacity: 1),
                collapsed: .init(points: dot(end), width: 5, opacity: 1), color: color)
        }
        let guides: [MatchedStrokeMorphRoute] = routes.compactMap { route in
            guard let value = route.expected, value.isFinite else { return nil }
            let expected = min(1, max(0, value)), radius = route.ring.width / 2
            let angle = route.half == 0 ? -Double.pi / 2 + expected * 2 * Double.pi
                : (route.half < 0 ? Double.pi / 2 : -Double.pi / 2) + expected * Double.pi
            func radial(_ radius: Double) -> CGPoint { CGPoint(x: route.ring.midX + cos(angle) * radius, y: route.ring.midY + sin(angle) * radius) }
            let y = route.track.minY + 2.5 + (route.track.height - 2.5) * (1 - expected)
            return .init(id: "pace:" + route.id, participantID: "pace:" + route.id,
                expanded: .init(points: [radial(radius - 3.5), radial(radius + 3.5)], width: 1.5),
                collapsed: .init(points: [CGPoint(x: route.track.midX - 2.5, y: y), CGPoint(x: route.track.midX + 2.5, y: y)], width: 1.5), color: .white)
        }
        // Forecast guides must paint above both the value stroke and brand dot.
        return strokes + markers + guides
    }

    /// Model usage already has a straight horizontal source. Match each color
    /// interval to the vertical destination through the same transient engine.
    private static func stripStrokes(_ route: ClientQuotaMorphRoute) -> [MatchedStrokeMorphRoute] {
        let a = [CGPoint(x: route.ring.minX + 2, y: route.ring.midY), CGPoint(x: route.ring.maxX - 2, y: route.ring.midY)]
        let b = [CGPoint(x: route.track.midX, y: route.track.minY + 2), CGPoint(x: route.track.midX, y: route.track.maxY - 2)]
        var strokes = [MatchedStrokeMorphRoute(id: route.id + ":track", participantID: route.id,
            expanded: .init(points: a, width: 4, opacity: route.expandedTrackOpacity),
            collapsed: .init(points: b, width: 4, opacity: route.collapsedTrackOpacity), color: .white)]
        for segment in route.segments {
            let start = min(1, max(0, segment.start)), end = min(1, max(start, segment.end))
            guard end > start else { continue }
            strokes.append(.init(id: route.id + ":" + segment.id, participantID: route.id,
                expanded: .init(points: a, start: start, end: end, width: 4, opacity: 1),
                collapsed: .init(points: b, start: start, end: end, width: 4, opacity: 1), color: segment.color))
        }
        return strokes
    }

}

enum ClientQuotaMorphShape { case ring, strip }

struct ClientQuotaMorphRoute {
    let id: String
    let ring: CGRect
    let track: CGRect
    let half: Int
    let fraction: Double?
    let color: NSColor
    var segments: [ClientQuotaMorphColorSegment] = []
    var expandedTrackOpacity: Float = 0.15
    var collapsedTrackOpacity: Float = 0.12
    var fillOpacity: Float = 1
    var marker: CGRect? = nil
    var markerColor: NSColor? = nil
    var expected: Double? = nil
    var shape: ClientQuotaMorphShape = .ring
}

struct ClientQuotaMorphColorSegment {
    let id: String
    let start: Double
    let end: Double
    let color: NSColor
}

struct ClientQuotaMorphSurface: NSViewRepresentable {
    let expanded: Bool
    let enabled: Bool
    let routes: [ClientQuotaMorphRoute]
    @Environment(\.matchedStrokeMorphRegistry) private var registry
    func makeNSView(context: Context) -> MatchedStrokeMorphView { MatchedStrokeMorphView() }
    func updateNSView(_ view: MatchedStrokeMorphView, context: Context) {
        view.update(expanded: expanded, enabled: enabled, participantCount: routes.count, registry: registry) { ClientQuotaMorphGeometry.strokes(routes) }
    }
    static func dismantleNSView(_ view: MatchedStrokeMorphView, coordinator: ()) { view.clear() }
}
