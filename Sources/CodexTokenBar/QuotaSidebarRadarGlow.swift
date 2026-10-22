import AppKit
import QuartzCore
import SwiftUI

/// Compositor-only motion: no per-frame SwiftUI updates or layout of the rail.
struct QuotaSidebarRadarGlow: NSViewRepresentable {
    let edge: QuotaSidebarEdge
    let expanded: Bool
    func makeNSView(context: Context) -> QuotaSidebarRadarGlowView {
        let view = QuotaSidebarRadarGlowView()
        view.configure(edge: edge, expanded: expanded)
        return view
    }
    func updateNSView(_ view: QuotaSidebarRadarGlowView, context: Context) {
        view.configure(edge: edge, expanded: expanded)
    }
    static func dismantleNSView(_ view: QuotaSidebarRadarGlowView, coordinator: ()) { view.setMotionActive(false); view.stopObserving() }
}

@MainActor
final class QuotaSidebarRadarGlowView: NSView {
    private let pulse = CALayer()
    private let stroke = CALayer()
    private let gradient = CAGradientLayer()
    private let strokeMask = CAShapeLayer()
    private let clip = CAShapeLayer()
    private let halo = CAShapeLayer()
    private var edge: QuotaSidebarEdge = .right
    private var expanded = false
    private var geometry: Geometry?
    private(set) var motionActive = false
    private(set) var animationStartCount = 0
    private(set) var geometryApplicationCount = 0
    private struct Geometry: Equatable { let size: CGSize; let edge: QuotaSidebarEdge; let expanded: Bool; let scale: CGFloat }
    private lazy var probe: AnimationVisibilityView = {
        let view = AnimationVisibilityView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.includesMotionPolicy = true
        view.changed = { [weak self] in self?.setMotionActive($0) }
        return view
    }()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = clip
        layer?.addSublayer(pulse)
        pulse.addSublayer(halo); pulse.addSublayer(stroke)
        stroke.addSublayer(gradient); stroke.mask = strokeMask
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.red.withAlphaComponent(0.15).cgColor,
                           NSColor.red.cgColor, NSColor.red.withAlphaComponent(0.15).cgColor]
        gradient.locations = [0, 0.5, 1]
        strokeMask.fillColor = NSColor.clear.cgColor
        strokeMask.strokeColor = NSColor.white.cgColor; strokeMask.lineWidth = 1.5
        halo.fillColor = NSColor.clear.cgColor; halo.strokeColor = NSColor.red.withAlphaComponent(0.6).cgColor
        halo.lineWidth = 1.5; halo.shadowColor = NSColor.red.cgColor
        halo.shadowOpacity = 0.5; halo.shadowRadius = 3; halo.shadowOffset = .zero
        addSubview(probe)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGeometry(); probe.scheduleCheck() }
    override func layout() { super.layout(); updateGeometry() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateGeometry() }
    func configure(edge: QuotaSidebarEdge, expanded: Bool) {
        self.edge = edge; self.expanded = expanded
        updateGeometry(); probe.scheduleCheck()
    }
    func stopObserving() { probe.stop() }
    func setMotionActive(_ active: Bool) {
        guard motionActive != active else { return }
        motionActive = active
        if active {
            animationStartCount += 1
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0; turn.toValue = Double.pi * 2
            turn.duration = 3; turn.repeatCount = .infinity
            gradient.add(turn, forKey: "radarTurn")
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.7; breathe.toValue = 1
            breathe.duration = 0.8; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.add(breathe, forKey: "radarPulse")
        } else {
            gradient.removeAnimation(forKey: "radarTurn")
            pulse.removeAnimation(forKey: "radarPulse")
        }
    }
    var hasMotionAnimations: Bool { gradient.animation(forKey: "radarTurn") != nil || pulse.animation(forKey: "radarPulse") != nil }
    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let next = Geometry(size: bounds.size, edge: edge, expanded: expanded, scale: scale)
        guard geometry != next else { return }
        geometry = next; geometryApplicationCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pulse.frame = bounds; stroke.frame = bounds; halo.frame = bounds
        strokeMask.frame = bounds; clip.frame = bounds
        let radius: CGFloat = expanded ? 22 : 8
        clip.path = Self.path(in: bounds, radius: radius, edge: edge)
        strokeMask.path = Self.path(in: bounds.insetBy(dx: 0.75, dy: 0.75), radius: max(0, radius - 0.75), edge: edge)
        halo.path = strokeMask.path
        // A square keeps the rotating gradient covering a tall, narrow rail.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for item in [pulse, stroke, gradient, strokeMask, clip, halo] { item.contentsScale = scale }
    }
    static func path(in rect: CGRect, radius: CGFloat, edge: QuotaSidebarEdge) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        let left = edge == .right ? r : 0, right = edge == .left ? r : 0
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + right), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - right, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - left), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + left))
        p.addQuadCurve(to: CGPoint(x: rect.minX + left, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath(); return p
    }
}
