import AppKit
import SwiftUI
import QuartzCore

/// Reusable matched-path animation. Callers supply endpoints; this layer knows
/// nothing about clients, quota windows, circles, bars or token statistics.
struct MatchedStrokeMorphEndpoint {
    let points: [CGPoint]
    var start: CGFloat = 0
    var end: CGFloat = 1
    var width: CGFloat = 3
    var opacity: Float = 1
}

struct MatchedStrokeMorphRoute {
    let id: String
    let participantID: String
    let expanded: MatchedStrokeMorphEndpoint
    let collapsed: MatchedStrokeMorphEndpoint
    let color: NSColor
    var opacityGroup: String? = nil
}

struct MatchedStrokeMorphTiming {
    var openingDuration = 0.44
    var closingDuration = 0.44
    static let standard = Self()
    static func progress(_ t: Double, expanding: Bool) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        return expanding ? (1 - (1 + 8 * t) * exp(-8 * t)) / (1 - 9 * exp(-8)) : 1 - pow(1 - t, 3)
    }
}

enum MatchedStrokeMorphGeometry {
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
        return points.count >= 2 ? points : nil
    }
    static func interpolate(_ a: [CGPoint], _ b: [CGPoint], progress: Double) -> CGPath {
        path(zip(a, b).map { x, y in CGPoint(x: x.x + (y.x - x.x) * progress, y: x.y + (y.y - x.y) * progress) })
    }
}

/// Original native participants remain mounted. Native visibility and animation
/// layers exchange ownership in the SAME CA transaction, without delayed SwiftUI
/// opacity updates or a blank frame at either endpoint.
@MainActor final class MatchedStrokeMorphRegistry: ObservableObject {
    private struct Entry {
        weak var view: NSView?
        let ids: Set<String>
    }
    private var entries: [UUID: Entry] = [:]
    private var owners: [UUID: Set<String>] = [:]
    var registeredViewCount: Int { entries.values.filter { $0.view != nil }.count }
    var coveredViewCount: Int { entries.values.filter { $0.view?.alphaValue == 0 }.count }
    func register(_ key: UUID, view: NSView, ids: Set<String>) {
        let entry = Entry(view: view, ids: ids)
        entries[key] = entry
        apply(entry)
    }
    func unregister(_ key: UUID) {
        entries.removeValue(forKey: key)?.view?.alphaValue = 1
    }
    func cover(_ ids: Set<String>, owner: UUID) {
        if ids.isEmpty { owners.removeValue(forKey: owner) } else { owners[owner] = ids }
        entries = entries.filter { $0.value.view != nil }
        entries.values.forEach(apply)
    }
    private func apply(_ entry: Entry) {
        let covered = owners.values.contains { !$0.isDisjoint(with: entry.ids) }
        let alpha: CGFloat = covered ? 0 : 1
        if entry.view?.alphaValue != alpha { entry.view?.alphaValue = alpha }
    }
}

private struct MatchedStrokeMorphRegistryKey: EnvironmentKey {
    static let defaultValue: MatchedStrokeMorphRegistry? = nil
}
extension EnvironmentValues {
    var matchedStrokeMorphRegistry: MatchedStrokeMorphRegistry? {
        get { self[MatchedStrokeMorphRegistryKey.self] }
        set { self[MatchedStrokeMorphRegistryKey.self] = newValue }
    }
}

/// Explicit sizing preserves the existing layout. With no registry this is just
/// the original SwiftUI content, useful in every other screen and in previews.
struct MatchedStrokeMorphParticipant<Content: View>: View {
    let ids: Set<String>
    let size: CGSize
    @ViewBuilder let content: () -> Content
    @Environment(\.matchedStrokeMorphRegistry) private var registry
    @Environment(\.self) private var environment
    var body: some View {
        Group {
            if let registry {
                MatchedStrokeMorphHost(content: AnyView(content().environment(\.self, environment)), ids: ids, size: size, registry: registry)
            } else { content() }
        }.frame(width: size.width, height: size.height)
    }
}

private struct MatchedStrokeMorphHost: NSViewRepresentable {
    let content: AnyView
    let ids: Set<String>
    let size: CGSize
    let registry: MatchedStrokeMorphRegistry
    func makeNSView(context: Context) -> MatchedStrokeMorphHostView {
        MatchedStrokeMorphHostView(content: content)
    }
    func updateNSView(_ view: MatchedStrokeMorphHostView, context: Context) {
        let probe = SidebarMotionProbe.stamp(); defer { SidebarMotionProbe.elapsed(probe, "nativeHostUpdate") }
        view.host.rootView = content
        if view.host.frame.size != size { view.host.setFrameSize(size) }
        if view.registry !== registry { view.registry?.unregister(view.key) }
        view.registry = registry
        registry.register(view.key, view: view, ids: ids)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MatchedStrokeMorphHostView, context: Context) -> CGSize? { size }
    static func dismantleNSView(_ view: MatchedStrokeMorphHostView, coordinator: ()) { view.registry?.unregister(view.key) }
}

@MainActor private final class MatchedStrokeMorphHostView: NSView {
    let key = UUID()
    let host: NSHostingView<AnyView>
    weak var registry: MatchedStrokeMorphRegistry?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(content: AnyView) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true; host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); if host.frame != bounds { host.frame = bounds } }
}

@MainActor final class MatchedStrokeMorphView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var expanded: Bool?
    private var generation = 0
    private let owner = UUID()
    private weak var registry: MatchedStrokeMorphRegistry?
    private var shapes: [String: CAShapeLayer] = [:]
    private var opacityGroups: [String: CALayer] = [:]
    private var shapeGroups: [String: String] = [:]
    private var startingStates: [String: MatchedStrokeMorphEndpoint] = [:]
    private var completion: MatchedStrokeMorphCompletion?
    private var cleanupTask: Task<Void, Never>?
    private(set) var availableRouteCount = 0
    private(set) var animationsStarted = 0
    private(set) var lastPreparationMilliseconds = 0.0
    var morphLayerCount: Int { shapes.count }
    var compositingGroupCount: Int { opacityGroups.count }
    var isAnimating: Bool { layer?.animation(forKey: "morph-completion") != nil }
    var coveredParticipantViewCount: Int { registry?.coveredViewCount ?? 0 }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.isGeometryFlipped = true }
    required init?(coder: NSCoder) { nil }
    convenience init() { self.init(frame: .zero) }

    func clear() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        generation += 1
        cleanupTask?.cancel(); cleanupTask = nil
        registry?.cover([], owner: owner)
        layer?.removeAllAnimations()
        shapes.values.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        opacityGroups.values.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        opacityGroups.removeAll(); shapeGroups.removeAll()
        shapes.removeAll(); startingStates.removeAll(); completion = nil
        CATransaction.commit()
    }

    func update(expanded next: Bool, enabled: Bool, participantCount: Int,
                registry: MatchedStrokeMorphRegistry? = nil, timing: MatchedStrokeMorphTiming = .standard,
                routes: () -> [MatchedStrokeMorphRoute]) {
        let previous = expanded; expanded = next; availableRouteCount = participantCount
        guard enabled else { clear(); return }
        guard let previous, previous != next else { return }
        let started = CACurrentMediaTime()
        // Before the first render commit, presentation() may be nil. The
        // model already holds the destination; using it would flash a shape
        // that was never visible. Keep the real start as a fallback instead.
        let snapshots = shapes.reduce(into: [String: MatchedStrokeMorphEndpoint]()) { result, entry in
            let (id, shape) = entry
            if let p = shape.presentation(), let points = MatchedStrokeMorphGeometry.vertices(p.path) {
                let groupOpacity = shapeGroups[id].flatMap { opacityGroups[$0]?.presentation()?.opacity ?? startingStates[id]?.opacity } ?? 1
                result[id] = MatchedStrokeMorphEndpoint(points: points, start: p.strokeStart, end: p.strokeEnd, width: p.lineWidth, opacity: p.opacity * groupOpacity)
            } else if shape.animation(forKey: "matched-stroke") != nil, let source = startingStates[id] {
                result[id] = source
            } else if let points = MatchedStrokeMorphGeometry.vertices(shape.path) {
                result[id] = MatchedStrokeMorphEndpoint(points: points, start: shape.strokeStart, end: shape.strokeEnd, width: shape.lineWidth, opacity: shape.opacity)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clear(); self.registry = registry
        let routes = routes().filter { route in
            let a = route.expanded.points, b = route.collapsed.points
            func valid(_ endpoint: MatchedStrokeMorphEndpoint) -> Bool {
                endpoint.width.isFinite && endpoint.width > 0 && endpoint.opacity.isFinite && (0...1).contains(endpoint.opacity)
                    && endpoint.start.isFinite && endpoint.end.isFinite && (0...1).contains(endpoint.start) && (endpoint.start...1).contains(endpoint.end)
            }
            return a.count >= 2 && a.count == b.count && valid(route.expanded) && valid(route.collapsed)
                && (a + b).allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
        guard let layer, !routes.isEmpty else { CATransaction.commit(); return }
        let duration = next ? timing.openingDuration : timing.closingDuration
        let currentGeneration = generation
        registry?.cover(Set(routes.map(\.participantID)), owner: owner)
        for route in routes {
            let from = previous ? route.expanded : route.collapsed, to = next ? route.expanded : route.collapsed
            let snapshot = snapshots[route.id].flatMap { $0.points.count == to.points.count ? $0 : nil } ?? from
            let source = snapshot.points
            let style = (snapshot.start, snapshot.end, snapshot.width, snapshot.opacity)
            startingStates[route.id] = snapshot
            let shape = CAShapeLayer()
            shape.fillColor = nil; shape.strokeColor = route.color.cgColor; shape.lineCap = .round; shape.lineJoin = .round
            shape.path = MatchedStrokeMorphGeometry.path(to.points)
            shape.strokeStart = to.start; shape.strokeEnd = to.end; shape.lineWidth = to.width; shape.opacity = to.opacity
            // Closing is exactly the same cubic as the frame clock. Let CA
            // interpolate two endpoints rather than allocating 17 paths.
            let closingCurve = CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
            func values(_ key: String, _ a: Double, _ b: Double) -> CAAnimation {
                if !next {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = a; animation.toValue = b
                    animation.duration = duration; animation.timingFunction = closingCurve
                    return animation
                }
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = (0...16).map { i in a + (b - a) * MatchedStrokeMorphTiming.progress(Double(i) / 16, expanding: true) }
                animation.duration = duration
                return animation
            }
            let path: CAPropertyAnimation
            if next {
                let animation = CAKeyframeAnimation(keyPath: "path")
                animation.values = (0...16).map { i in MatchedStrokeMorphGeometry.interpolate(source, to.points, progress: MatchedStrokeMorphTiming.progress(Double(i) / 16, expanding: true)) }
                animation.duration = duration; animation.calculationMode = .linear
                path = animation
            } else {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = MatchedStrokeMorphGeometry.path(source)
                animation.toValue = MatchedStrokeMorphGeometry.path(to.points)
                animation.duration = duration; animation.timingFunction = closingCurve
                path = animation
            }
            let group = CAAnimationGroup()
            group.animations = [path, values("strokeStart", style.0, to.start), values("strokeEnd", style.1, to.end),
                                values("lineWidth", style.2, to.width)]
            group.duration = duration
            if let key = route.opacityGroup {
                let container: CALayer
                if let existing = opacityGroups[key] { container = existing }
                else {
                    container = CALayer(); container.frame = layer.bounds; container.opacity = to.opacity; container.allowsGroupOpacity = true
                    layer.addSublayer(container); opacityGroups[key] = container
                    container.add(values("opacity", Double(style.3), Double(to.opacity)), forKey: "matched-opacity")
                }
                shape.opacity = 1; container.addSublayer(shape); shapeGroups[route.id] = key
            } else {
                group.animations?.append(values("opacity", Double(style.3), Double(to.opacity)))
                layer.addSublayer(shape)
            }
            shapes[route.id] = shape
            shape.add(group, forKey: "matched-stroke")
        }
        let completion = MatchedStrokeMorphCompletion { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.clear()
        }
        self.completion = completion
        let sentinel = CABasicAnimation(keyPath: "opacity")
        sentinel.fromValue = 1; sentinel.toValue = 1; sentinel.duration = duration; sentinel.delegate = completion
        layer.add(sentinel, forKey: "morph-completion")
        CATransaction.commit()
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration + 0.05)) } catch { return }
            guard let self, self.generation == currentGeneration else { return }
            self.clear()
        }
        animationsStarted += 1
        lastPreparationMilliseconds = (CACurrentMediaTime() - started) * 1000
    }
}

private final class MatchedStrokeMorphCompletion: NSObject, CAAnimationDelegate {
    private let completed: @MainActor () -> Void
    init(_ completed: @escaping @MainActor () -> Void) { self.completed = completed }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        let finished = completed
        Task { @MainActor in finished() }
    }
}
