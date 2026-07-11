import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct FloatingUnreadShimmerOverlay: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    func makeNSView(context: Context) -> FloatingUnreadShimmerView {
        let view = FloatingUnreadShimmerView()
        view.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
        return view
    }

    func updateNSView(_ nsView: FloatingUnreadShimmerView, context: Context) {
        nsView.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
    }

    private var nsColor: NSColor {
        FloatingPanelColorTools.deviceRGB(NSColor(color))
    }
}

final class FloatingUnreadShimmerView: NSView {
    private struct RenderRequest: Sendable {
        let size: CGSize
        let backingScale: CGFloat
        let color: FloatingUnreadRenderColor
        let cornerRadius: CGFloat
        let scale: CGFloat
    }

    private static let animationKey = "floatingUnreadShimmerFrames"

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
    private let cycleDuration: CFTimeInterval = 2.1
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
        let targetFramesPerSecond = targetFramesPerSecond
        let descriptor = Self.frameDescriptor(
            request: request,
            cycleDuration: cycleDuration,
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
        targetFramesPerSecond: Int
    ) -> FloatingUnreadFrameCacheDescriptor {
        FloatingUnreadFrameCacheDescriptor(
            effect: "shimmer",
            size: request.size,
            backingScale: request.backingScale,
            color: request.color,
            cornerRadius: request.cornerRadius,
            scale: request.scale,
            cycleDuration: cycleDuration,
            activeFraction: 1,
            framesPerSecond: targetFramesPerSecond
        )
    }

    private static nonisolated func renderUncachedFrames(
        request: RenderRequest,
        cycleDuration: CFTimeInterval,
        targetFramesPerSecond: Int
    ) -> [CGImage] {
        let pixelWidth = max(1, Int((request.size.width * request.backingScale).rounded(.up)))
        let pixelHeight = max(1, Int((request.size.height * request.backingScale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: cycleDuration,
            targetFramesPerSecond: targetFramesPerSecond
        )

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
            Self.drawShimmerFrame(in: context, request: request, phase: Double(index) / Double(frameCount))
            return context.makeImage()
        }
    }

    private static nonisolated func drawShimmerFrame(in context: CGContext, request: RenderRequest, phase: Double) {
        let size = request.size
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: request.cornerRadius,
            cornerHeight: request.cornerRadius,
            transform: nil
        ))
        context.clip()

        let pulse = (sin(phase * .pi * 4) + 1) / 2
        context.setFillColor(request.color.cgColor(alpha: 0.026 + 0.020 * pulse))
        context.fill(rect)
        context.setBlendMode(.screen)

        let bandWidth = max(size.width * 0.62, 76 * request.scale)
        let bandHeight = size.height * 2.0
        let fromX = -bandWidth * 0.8
        let toX = size.width + bandWidth * 1.15
        let centerX = fromX + (toX - fromX) * CGFloat(phase)
        let centerY = size.height / 2

        Self.drawSweepBand(
            in: context,
            center: CGPoint(x: centerX, y: centerY),
            width: bandWidth,
            height: bandHeight,
            angle: -0.20,
            colors: [
                FloatingUnreadRenderColor.clear.cgColor(),
                request.color.cgColor(alpha: 0.28),
                FloatingUnreadRenderColor.white.cgColor(alpha: 0.46),
                request.color.cgColor(alpha: 0.22),
                FloatingUnreadRenderColor.clear.cgColor()
            ],
            locations: [0.0, 0.30, 0.50, 0.70, 1.0]
        )

        Self.drawSweepBand(
            in: context,
            center: CGPoint(x: centerX + bandWidth * 0.18, y: centerY),
            width: max(12 * request.scale, bandWidth * 0.16),
            height: bandHeight,
            angle: -0.20,
            colors: [
                FloatingUnreadRenderColor.clear.cgColor(),
                FloatingUnreadRenderColor.white.cgColor(alpha: 0),
                FloatingUnreadRenderColor.white.cgColor(alpha: 0.28),
                FloatingUnreadRenderColor.clear.cgColor()
            ],
            locations: [0.0, 0.45, 0.55, 1.0]
        )
        context.restoreGState()
    }

    private static nonisolated func drawSweepBand(
        in context: CGContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat,
        angle: CGFloat,
        colors: [CGColor],
        locations: [CGFloat]
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else {
            return
        }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.midY),
            end: CGPoint(x: rect.maxX, y: rect.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
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
}
