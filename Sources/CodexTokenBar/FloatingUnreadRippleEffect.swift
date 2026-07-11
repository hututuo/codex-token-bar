import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct FloatingUnreadRippleOverlay: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    func makeNSView(context: Context) -> FloatingUnreadSpriteRippleView {
        let view = FloatingUnreadSpriteRippleView()
        view.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
        return view
    }

    func updateNSView(_ nsView: FloatingUnreadSpriteRippleView, context: Context) {
        nsView.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
    }

    private var nsColor: NSColor {
        FloatingPanelColorTools.deviceRGB(NSColor(color))
    }
}

final class FloatingUnreadSpriteRippleView: NSView {
    private struct RippleSource {
        let point: CGPoint
        let arrivalDistance: CGFloat
        let strength: CGFloat
        let isDirect: Bool
    }

    private struct RenderRequest: Sendable {
        let size: CGSize
        let backingScale: CGFloat
        let color: FloatingUnreadRenderColor
        let cornerRadius: CGFloat
        let scale: CGFloat
    }

    private static let animationKey = "floatingUnreadRippleFrames"

    private let imageLayer = CALayer()
    private let renderCoordinator = FloatingUnreadRenderRequestCoordinator()
    private var cachedFrames: [CGImage] = []
    private var pendingRenderWorkItem: DispatchWorkItem?
    private var animationStartLayerTime: CFTimeInterval?
    private var currentColor = FloatingUnreadRenderColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    private var currentCornerRadius: CGFloat = 14
    private var currentScale: CGFloat = 1
    private var lastBounds: CGRect = .zero
    private var lastBackingScale: CGFloat = 0
    private let cycleDuration: CFTimeInterval = 3.25
    private let activeFraction = 0.92
    private let targetFramesPerSecond = 30
    private let resizeRenderDebounce: TimeInterval = 0.14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRootLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRootLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
        } else {
            updateLayoutIfNeeded(force: true)
            startAnimations()
        }
    }

    override func layout() {
        super.layout()
        updateLayoutIfNeeded(force: false)
    }

    func configure(color: NSColor, cornerRadius: CGFloat, scale: CGFloat) {
        let nextColor = FloatingUnreadRenderColor(color)
        let nextScale = max(scale, 0.1)
        let needsLayout = !nextColor.isApproximatelyEqual(to: currentColor)
            || abs(currentScale - nextScale) > 0.001
            || abs(currentCornerRadius - cornerRadius) > 0.001
        currentColor = nextColor
        currentCornerRadius = cornerRadius
        currentScale = nextScale
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        updateLayoutIfNeeded(force: needsLayout)
    }

    private func setupRootLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    private func updateLayoutIfNeeded(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let rawBackingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: cycleDuration,
            targetFramesPerSecond: targetFramesPerSecond
        )
        guard let backingScale = FloatingUnreadFrameBudget.cappedBackingScale(
            size: bounds.size,
            preferredScale: rawBackingScale,
            frameCount: frameCount
        ) else {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = currentCornerRadius
        layer?.cornerCurve = .continuous
        imageLayer.frame = bounds
        imageLayer.contentsScale = backingScale
        CATransaction.commit()

        guard isReasonableRenderableSize(bounds.size) else {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
            return
        }
        guard force || bounds != lastBounds || abs(backingScale - lastBackingScale) > 0.01 else {
            return
        }

        let request = RenderRequest(
            size: bounds.size,
            backingScale: backingScale,
            color: currentColor,
            cornerRadius: currentCornerRadius,
            scale: currentScale
        )
        requestFrameRender(request, immediate: cachedFrames.isEmpty)
    }

    private func isReasonableRenderableSize(_ size: CGSize) -> Bool {
        let maxSize = FloatingTokenPanelMetrics.size(scale: FloatingTokenPanelMetrics.scaleRange.upperBound)
        return size.width <= maxSize.width + 32
            && size.height <= maxSize.height + 32
    }

    private func requestFrameRender(_ request: RenderRequest, immediate: Bool) {
        let cycleDuration = cycleDuration
        let activeFraction = activeFraction
        let targetFramesPerSecond = targetFramesPerSecond
        let descriptor = Self.frameDescriptor(
            request: request,
            cycleDuration: cycleDuration,
            activeFraction: activeFraction,
            targetFramesPerSecond: targetFramesPerSecond
        )
        guard let token = renderCoordinator.begin(descriptor: descriptor) else { return }
        cancelPendingRender(invalidateRequest: false)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.renderCoordinator.accepts(token) else { return }
            guard self.window != nil else {
                self.renderCoordinator.invalidate()
                return
            }
            let cached = FloatingUnreadFrameCache.requestFrames(
                descriptor: descriptor,
                render: {
                    Self.renderUncachedFrames(
                        request: request,
                        cycleDuration: cycleDuration,
                        activeFraction: activeFraction,
                        targetFramesPerSecond: targetFramesPerSecond
                    )
                },
                completion: { [weak self] frames in
                    self?.applyRenderedFrames(frames, request: request, token: token)
                }
            )
            if let cached {
                self.applyRenderedFrames(cached, request: request, token: token)
            }
        }
        pendingRenderWorkItem = workItem
        if immediate {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + resizeRenderDebounce, execute: workItem)
        }
    }

    private func applyRenderedFrames(
        _ frames: [CGImage],
        request: RenderRequest,
        token: FloatingUnreadRenderRequestToken
    ) {
        guard renderCoordinator.accepts(token), window != nil else { return }
        pendingRenderWorkItem = nil
        guard !frames.isEmpty else { return }
        let phaseOffset = currentAnimationPhaseOffset()
        stopAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastBounds = CGRect(origin: .zero, size: request.size)
        lastBackingScale = request.backingScale
        imageLayer.frame = CGRect(origin: .zero, size: request.size)
        imageLayer.contentsScale = request.backingScale
        cachedFrames = frames
        imageLayer.contents = frames.first
        CATransaction.commit()
        startAnimations(phaseOffset: phaseOffset)
    }

    private static nonisolated func frameDescriptor(
        request: RenderRequest,
        cycleDuration: CFTimeInterval,
        activeFraction: Double,
        targetFramesPerSecond: Int
    ) -> FloatingUnreadFrameCacheDescriptor {
        FloatingUnreadFrameCacheDescriptor(
            effect: "ripple",
            size: request.size,
            backingScale: request.backingScale,
            color: request.color,
            cornerRadius: request.cornerRadius,
            scale: request.scale,
            cycleDuration: cycleDuration,
            activeFraction: activeFraction,
            framesPerSecond: targetFramesPerSecond
        )
    }

    private static nonisolated func renderUncachedFrames(
        request: RenderRequest,
        cycleDuration: CFTimeInterval,
        activeFraction: Double,
        targetFramesPerSecond: Int
    ) -> [CGImage] {
        let pixelWidth = max(1, Int((request.size.width * request.backingScale).rounded(.up)))
        let pixelHeight = max(1, Int((request.size.height * request.backingScale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let frameCount = Self.frameCount(cycleDuration: cycleDuration, targetFramesPerSecond: targetFramesPerSecond)

        return (0..<frameCount).compactMap { index in
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.scaleBy(x: request.backingScale, y: request.backingScale)
            Self.drawRippleFrame(
                in: context,
                request: request,
                phase: Double(index) / Double(frameCount),
                activeFraction: activeFraction
            )
            return context.makeImage()
        }
    }

    private static nonisolated func frameCount(cycleDuration: CFTimeInterval, targetFramesPerSecond: Int) -> Int {
        FloatingUnreadFrameBudget.frameCount(
            cycleDuration: cycleDuration,
            targetFramesPerSecond: targetFramesPerSecond
        )
    }

    private static nonisolated func drawRippleFrame(
        in context: CGContext,
        request: RenderRequest,
        phase: Double,
        activeFraction: Double
    ) {
        let size = request.size
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: request.cornerRadius, cornerHeight: request.cornerRadius, transform: nil))
        context.clip()

        let pulse = (sin(phase * .pi * 2) + 1) / 2
        context.setFillColor(request.color.cgColor(alpha: 0.020 + 0.014 * pulse))
        context.fill(rect)

        if phase < activeFraction {
            Self.drawCircularRippleReflections(in: context, request: request, phase: phase / activeFraction)
        }
        context.restoreGState()
    }

    private static nonisolated func drawCircularRippleReflections(in context: CGContext, request: RenderRequest, phase: Double) {
        let size = request.size
        let fadeOut = Self.smoothPulseFade(phase)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(max(size.width, size.height) * 0.82, size.height * 2.25)
        let baseRadius = maxRadius * CGFloat(Self.easeOutSine(phase))
        let waveAlpha = CGFloat(fadeOut) * (1.04 - 0.26 * CGFloat(phase))
        let scale = request.scale
        let rings: [(offset: CGFloat, alpha: CGFloat, thickness: CGFloat)] = [
            (0, 1.00, 2.40),
            (-6.2 * scale, 0.66, 2.08),
            (-12.4 * scale, 0.46, 1.82),
            (-18.6 * scale, 0.34, 1.58),
            (-24.8 * scale, 0.24, 1.36)
        ]
        let sources = Self.rippleSources(size: size, center: center)

        for ring in rings {
            let radius = baseRadius + ring.offset
            guard radius > 1.4 * scale else { continue }
            let thickness = ring.thickness * scale

            for source in sources {
                let reflectionFade = source.isDirect
                    ? 1
                    : Self.smoothStep((radius - source.arrivalDistance) / max(12 * scale, 1))
                guard reflectionFade > 0.01 else { continue }
                let alpha = waveAlpha * ring.alpha * source.strength * reflectionFade
                Self.drawCircularRing(
                    in: context,
                    color: request.color,
                    scale: scale,
                    center: source.point,
                    radius: radius,
                    thickness: thickness,
                    alpha: alpha
                )
            }
        }

    }

    private static nonisolated func drawCircularRing(
        in context: CGContext,
        color: FloatingUnreadRenderColor,
        scale: CGFloat,
        center: CGPoint,
        radius: CGFloat,
        thickness: CGFloat,
        alpha: CGFloat
    ) {
        guard alpha > 0.006 else { return }
        let outerRadius = max(radius + thickness / 2, 0.2)
        let innerRadius = max(radius - thickness / 2, 0.1)

        context.saveGState()
        context.setFillColor(color.cgColor(alpha: alpha * 0.54))
        context.addEllipse(in: Self.circleRect(center: center, radius: outerRadius))
        context.addEllipse(in: Self.circleRect(center: center, radius: innerRadius))
        context.drawPath(using: .eoFill)

        context.setStrokeColor(FloatingUnreadRenderColor.white.cgColor(alpha: alpha * 0.17))
        context.setLineWidth(max(0.18, 0.24 * scale))
        context.addEllipse(in: Self.circleRect(center: center, radius: radius))
        context.strokePath()
        context.restoreGState()
    }

    private func startAnimations(phaseOffset: CFTimeInterval = 0) {
        guard window != nil, cachedFrames.count > 1 else { return }
        guard imageLayer.animation(forKey: Self.animationKey) == nil else { return }
        let loopFrames = cachedFrames + [cachedFrames[0]]
        let lastIndex = max(loopFrames.count - 1, 1)
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let offset = min(max(phaseOffset, 0), cycleDuration)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = loopFrames
        animation.keyTimes = (0..<loopFrames.count).map { NSNumber(value: Double($0) / Double(lastIndex)) }
        animation.duration = cycleDuration
        animation.beginTime = layerTime - offset
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animationStartLayerTime = layerTime - offset
        imageLayer.add(animation, forKey: Self.animationKey)
    }

    private func stopAnimations() {
        imageLayer.removeAnimation(forKey: Self.animationKey)
        animationStartLayerTime = nil
    }

    private func currentAnimationPhaseOffset() -> CFTimeInterval {
        guard let animationStartLayerTime else { return 0 }
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let elapsed = max(0, layerTime - animationStartLayerTime)
        return elapsed.truncatingRemainder(dividingBy: cycleDuration)
    }

    private func clearFrameCache() {
        cachedFrames.removeAll()
        imageLayer.contents = nil
        lastBounds = .zero
        lastBackingScale = 0
    }

    private func cancelPendingRender(invalidateRequest: Bool = true) {
        if invalidateRequest {
            renderCoordinator.invalidate()
        }
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    private static nonisolated func rippleSources(size: CGSize, center: CGPoint) -> [RippleSource] {
        [
            RippleSource(point: center, arrivalDistance: 0, strength: 1.00, isDirect: true),
            RippleSource(point: CGPoint(x: center.x, y: -center.y), arrivalDistance: center.y, strength: 0.84, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: size.height + (size.height - center.y)), arrivalDistance: size.height - center.y, strength: 0.84, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: center.y - 2 * size.height), arrivalDistance: 2 * size.height - center.y, strength: 0.52, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: center.y + 2 * size.height), arrivalDistance: size.height + center.y, strength: 0.52, isDirect: false),
            RippleSource(point: CGPoint(x: -center.x, y: center.y), arrivalDistance: center.x, strength: 0.66, isDirect: false),
            RippleSource(point: CGPoint(x: size.width + (size.width - center.x), y: center.y), arrivalDistance: size.width - center.x, strength: 0.66, isDirect: false)
        ]
    }

    private static nonisolated func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static nonisolated func easeOutSine(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return sin(clamped * .pi / 2)
    }

    private static nonisolated func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static nonisolated func smoothPulseFade(_ value: Double) -> Double {
        let fadeStart = 0.80
        guard value > fadeStart else { return 1 }
        let t = min(max((value - fadeStart) / (1 - fadeStart), 0), 1)
        return Double(1 - Self.smoothStep(CGFloat(t)))
    }

    private static nonisolated func gaussian(_ value: Double, center: Double, width: Double) -> Double {
        let distance = (value - center) / max(width, 0.0001)
        return exp(-(distance * distance))
    }

}
