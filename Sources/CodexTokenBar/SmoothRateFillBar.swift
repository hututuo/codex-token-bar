import AppKit
import SwiftUI

struct SmoothRateFillBar: NSViewRepresentable {
    var fraction: Double
    let minimumFraction: Double
    var colors: [Color] = [AppTheme.accentCyan, AppTheme.accentBlue]
    var startPoint: UnitPoint = .leading
    var endPoint: UnitPoint = .trailing
    var animationDuration: TimeInterval = 0.2
    var modelRates: [ModelRateContribution]? = nil

    func makeNSView(context: Context) -> SmoothRateFillLayerView {
        let view = SmoothRateFillLayerView()
        view.update(
            fraction: fraction,
            minimumFraction: minimumFraction,
            colors: colors,
            startPoint: startPoint,
            endPoint: endPoint,
            animationDuration: animationDuration,
            animated: false,
            modelRates: modelRates
        )
        return view
    }

    func updateNSView(_ view: SmoothRateFillLayerView, context: Context) {
        view.update(
            fraction: fraction,
            minimumFraction: minimumFraction,
            colors: colors,
            startPoint: startPoint,
            endPoint: endPoint,
            animationDuration: animationDuration,
            animated: true,
            modelRates: modelRates
        )
    }
}

final class SmoothRateFillLayerView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var fraction: Double = 0
    private var minimumFraction: Double = 0
    private var fillColors: [Color] = []
    private var modelRates: [ModelRateContribution]?
    private var gradientStartPoint = UnitPoint.leading
    private var gradientEndPoint = UnitPoint.trailing
    private var animationDuration: TimeInterval = 0.2
    private var appliedStyle: FillStyle?
    private struct FillStyle: Equatable {
        let scale: CGFloat
        let colors: [Color]
        let rates: [ModelRateContribution]?
        let start: UnitPoint
        let end: UnitPoint
        let appearance: NSAppearance.Name
    }
    private(set) var styleApplicationCount = 0
    private var lastAppliedWidth: CGFloat?
    private var lastAppliedHeight: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        gradientLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.masksToBounds = true
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        applyFill(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appliedStyle = nil
        applyFill(animated: false)
    }

    func update(
        fraction: Double,
        minimumFraction: Double,
        colors: [Color],
        startPoint: UnitPoint,
        endPoint: UnitPoint,
        animationDuration: TimeInterval,
        animated: Bool,
        modelRates: [ModelRateContribution]? = nil
    ) {
        self.modelRates = modelRates
        self.fraction = fraction
        self.minimumFraction = minimumFraction
        self.fillColors = colors
        self.gradientStartPoint = startPoint
        self.gradientEndPoint = endPoint
        self.animationDuration = animationDuration
        applyFill(animated: animated)
    }

    private func applyFill(animated: Bool) {
        let height = max(bounds.height, 0)
        let width = max(bounds.width, 0)
        guard height > 0, width > 0 else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fillFraction = min(1, max(minimumFraction, fraction))
        let rawWidth = max(0, width * CGFloat(fillFraction))
        let pixelWidth = (rawWidth * scale).rounded(.toNearestOrAwayFromZero) / scale
        let clampedWidth = min(width, pixelWidth)
        let previousWidth = lastAppliedWidth
        let previousHeight = lastAppliedHeight
        let visiblePixelChanged = previousWidth.map { abs($0 - clampedWidth) >= (1 / scale) } ?? true
        let heightChanged = previousHeight.map { abs($0 - height) >= (1 / scale) } ?? true

        updateGradientConfiguration(scale: scale)

        guard visiblePixelChanged || heightChanged else { return }
        lastAppliedWidth = clampedWidth
        lastAppliedHeight = height

        let oldBounds = gradientLayer.bounds
        let newBounds = CGRect(x: 0, y: 0, width: clampedWidth, height: height)
        let newCornerRadius = min(clampedWidth, height) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.position = CGPoint(x: 0, y: height / 2)
        gradientLayer.bounds = newBounds
        gradientLayer.cornerRadius = newCornerRadius
        CATransaction.commit()

        guard animated, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let previousWidth,
              previousWidth > 0,
              clampedWidth > 0,
              abs(previousWidth - clampedWidth) >= (1 / scale) else {
            return
        }

        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = oldBounds.width
        animation.toValue = clampedWidth
        animation.duration = min(max(animationDuration, 0.12), 0.22)
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        gradientLayer.add(animation, forKey: "smoothRateFillWidth")
    }

    private func updateGradientConfiguration(scale: CGFloat) {
        let style = FillStyle(scale: scale, colors: fillColors, rates: modelRates,
            start: gradientStartPoint, end: gradientEndPoint, appearance: effectiveAppearance.name)
        guard appliedStyle != style else { return }
        appliedStyle = style
        styleApplicationCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gradientLayer.contentsScale = scale
        if let modelRates {
            let stops = ModelRatePresentation.stops(modelRates)
            gradientLayer.colors = stops.map { nsColor(from: $0.color).cgColor }
            gradientLayer.locations = stops.map { NSNumber(value: Double($0.location)) }
            gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            gradientLayer.colors = fillColors.map { nsColor(from: $0).cgColor }
            gradientLayer.locations = nil
            gradientLayer.startPoint = CGPoint(x: gradientStartPoint.x, y: gradientStartPoint.y)
            gradientLayer.endPoint = CGPoint(x: gradientEndPoint.x, y: gradientEndPoint.y)
        }
    }

    private func nsColor(from color: Color) -> NSColor {
        let nsColor = NSColor(color)
        return nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    }
}
