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
    static let settlingDuration = 0.12

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
            let endY = track.maxY - 2 - max(0, track.height - 4) * t
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
            // Flatten a whole ring as two convex halves; a single closed path
            // unwinding into a line produces an unwanted loop/curl mid-flight.
            return [Part(half: -2, start: 0, end: max(0, q * 2 - 1)),
                    Part(half: 2, start: 1 - min(1, q * 2), end: 1)]
        }
        return [Part(half: half, start: half < 0 ? 0 : 1 - q, end: half < 0 ? q : 1)]
    }

    static func path(_ points: [CGPoint]) -> CGPath { MatchedStrokeMorphGeometry.path(points) }
    static func vertices(_ path: CGPath?) -> [CGPoint]? { MatchedStrokeMorphGeometry.vertices(path) }
    static func interpolate(_ from: [CGPoint], _ to: [CGPoint], progress: Double) -> CGPath {
        MatchedStrokeMorphGeometry.interpolate(from, to, progress: progress)
    }

    static func strokes(_ routes: [ClientQuotaMorphRoute]) -> [MatchedStrokeMorphRoute] {
        routes.flatMap { route in
            parts(half: route.half, fraction: route.fraction).flatMap { part in
                [false, true].compactMap { fill -> MatchedStrokeMorphRoute? in
                    if fill && (route.fraction ?? 0) <= 0 { return nil }
                    let q = min(1, max(0, route.fraction ?? 0))
                    let barFraction = max(0, min(1, (q * route.track.height - 4) / max(1, route.track.height - 4)))
                    // Two halves of a whole ring share one final bar. Hide the
                    // duplicate at that endpoint so its track does not brighten.
                    let collapsedOpacity: Float = part.half == 2 ? 0 : (fill ? 1 : 0.12)
                    return MatchedStrokeMorphRoute(id: route.id + ":" + String(part.half) + (fill ? ":fill" : ":track"), participantID: route.id,
                        expanded: MatchedStrokeMorphEndpoint(points: points(ring: route.ring, track: route.track, half: part.half, progress: 0), start: fill ? part.start : 0, end: fill ? part.end : 1, width: 3, opacity: fill ? 1 : 0.15),
                        collapsed: MatchedStrokeMorphEndpoint(points: points(ring: route.ring, track: route.track, half: part.half, progress: 1), end: fill ? barFraction : 1, width: 4, opacity: collapsedOpacity),
                        color: fill ? route.color : .white)
                }
            }
        }
    }

}

struct ClientQuotaMorphRoute {
    let id: String
    let ring: CGRect
    let track: CGRect
    let half: Int
    let fraction: Double?
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
