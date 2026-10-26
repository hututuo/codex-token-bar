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
    static let closingDuration = 0.24
    static let openingDuration = 0.44
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

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    static func vertices(_ path: CGPath?) -> [CGPoint]? {
        guard let path else { return nil }
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        return points.count == segments + 1 ? points : nil
    }

    static func interpolate(_ from: [CGPoint], _ to: [CGPoint], progress: Double) -> CGPath {
        path(zip(from, to).map { a, b in CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress) })
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
    func makeNSView(context: Context) -> ClientQuotaMorphView { ClientQuotaMorphView() }
    func updateNSView(_ view: ClientQuotaMorphView, context: Context) {
        view.update(expanded: expanded, enabled: enabled, routes: routes)
    }
    static func dismantleNSView(_ view: ClientQuotaMorphView, coordinator: ()) { view.clear() }
}

/// Transient compositor layers. No TimelineView, timer, SwiftUI per-frame state or
/// window resizing. In steady state there are zero morph layers/animations.
@MainActor final class ClientQuotaMorphView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var expanded: Bool?
    private var generation = 0
    private var shapes: [String: CAShapeLayer] = [:]
    private var completion: ClientQuotaMorphCompletion?
    private var cleanupTask: Task<Void, Never>?
    private(set) var availableRouteCount = 0
    private(set) var animationsStarted = 0
    private(set) var lastPreparationMilliseconds = 0.0
    var morphLayerCount: Int { layer?.sublayers?.count ?? 0 }
    var isAnimating: Bool { layer?.animation(forKey: "morph-completion") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
    }
    required init?(coder: NSCoder) { nil }
    convenience init() { self.init(frame: .zero) }

    func clear() {
        generation += 1
        cleanupTask?.cancel(); cleanupTask = nil
        layer?.removeAllAnimations()
        shapes.values.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        shapes.removeAll()
        completion = nil
    }

    func update(expanded next: Bool, enabled: Bool, routes: [ClientQuotaMorphRoute]) {
        let previous = expanded
        expanded = next
        availableRouteCount = routes.count
        guard enabled else { clear(); return }
        guard let previous, previous != next else { return }
        let started = CACurrentMediaTime()
        // Capture the actual in-flight geometry before removing animations.
        let presentations = shapes.compactMapValues { ClientQuotaMorphGeometry.vertices($0.presentation()?.path ?? $0.path) }
        let intervals = shapes.mapValues { ($0.presentation()?.strokeStart ?? $0.strokeStart, $0.presentation()?.strokeEnd ?? $0.strokeEnd) }
        clear()
        guard let layer, !routes.isEmpty else { return }
        let duration = next ? ClientQuotaMorphGeometry.openingDuration : ClientQuotaMorphGeometry.closingDuration
        let currentGeneration = generation
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for route in routes {
            guard route.ring.width > 0, route.track.height >= 4 else { continue }
            for part in ClientQuotaMorphGeometry.parts(half: route.half, fraction: route.fraction) {
                let ring = ClientQuotaMorphGeometry.points(ring: route.ring, track: route.track, half: part.half, progress: 0)
                let bar = ClientQuotaMorphGeometry.points(ring: route.ring, track: route.track, half: part.half, progress: 1)
                for fill in [false, true] {
                    if fill && (route.fraction ?? 0) <= 0 { continue }
                    let key = route.id + ":" + String(part.half) + (fill ? ":fill" : ":track")
                    let source = presentations[key] ?? (previous ? ring : bar)
                    let destination = next ? ring : bar
                    let shape = CAShapeLayer()
                    shape.fillColor = nil
                    shape.strokeColor = fill ? route.color.cgColor : NSColor.white.withAlphaComponent(0.13).cgColor
                    shape.lineCap = .round; shape.lineJoin = .round
                    let q = min(1, max(0, route.fraction ?? 0))
                    let fromInterval = intervals[key] ?? (fill && previous ? (part.start, part.end) : (0, fill ? q : 1))
                    let endInterval = fill && next ? (part.start, part.end) : (0, fill ? q : 1)
                    shape.strokeStart = endInterval.0
                    shape.strokeEnd = endInterval.1
                    shape.lineWidth = next ? 3 : 4
                    shape.path = ClientQuotaMorphGeometry.path(destination)
                    let animation = CAKeyframeAnimation(keyPath: "path")
                    animation.values = (0...16).map { index in
                        let p = QuotaSidebarMotion.progress(Double(index) / 16, expanding: next)
                        return ClientQuotaMorphGeometry.interpolate(source, destination, progress: p)
                    }
                    animation.duration = duration
                    animation.calculationMode = .linear
                    func strokeAnimation(_ key: String, _ from: CGFloat, _ to: CGFloat) -> CAKeyframeAnimation {
                        let animation = CAKeyframeAnimation(keyPath: key)
                        animation.values = (0...16).map { index in
                            let p = QuotaSidebarMotion.progress(Double(index) / 16, expanding: next)
                            return from + (to - from) * p
                        }
                        animation.duration = duration
                        return animation
                    }
                    let strokeStart = strokeAnimation("strokeStart", fromInterval.0, endInterval.0)
                    let strokeEnd = strokeAnimation("strokeEnd", fromInterval.1, endInterval.1)
                    let width = CABasicAnimation(keyPath: "lineWidth")
                    width.fromValue = previous ? 3 : 4; width.toValue = next ? 3 : 4
                    width.duration = duration; width.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.1, 0.78, 1]; fade.duration = duration
                    shape.opacity = 0
                    let group = CAAnimationGroup(); group.animations = [animation, strokeStart, strokeEnd, width, fade]; group.duration = duration
                    layer.addSublayer(shape); shapes[key] = shape
                    shape.add(group, forKey: "quota-morph")
                }
            }
        }
        guard !shapes.isEmpty else { CATransaction.commit(); return }
        let completion = ClientQuotaMorphCompletion { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.clear()
        }
        self.completion = completion
        let sentinel = CABasicAnimation(keyPath: "opacity")
        sentinel.fromValue = 1; sentinel.toValue = 1; sentinel.duration = duration; sentinel.delegate = completion
        layer.add(sentinel, forKey: "morph-completion")
        CATransaction.commit()
        // Detached/occluded layer trees can omit the CA completion callback.
        // One cancellable deadline per transition is a cleanup backstop, not a
        // polling/render loop; normal CA completion cancels it immediately.
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration + 0.05)) } catch { return }
            guard let self, self.generation == currentGeneration else { return }
            self.clear()
        }
        animationsStarted += 1
        lastPreparationMilliseconds = (CACurrentMediaTime() - started) * 1000
    }
}

private final class ClientQuotaMorphCompletion: NSObject, CAAnimationDelegate {
    private let completed: @MainActor () -> Void
    init(_ completed: @escaping @MainActor () -> Void) { self.completed = completed }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        let finished = completed
        Task { @MainActor in finished() }
    }
}
