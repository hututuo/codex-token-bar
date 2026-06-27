import AppKit
import SwiftUI

struct SmoothRateFillBar: NSViewRepresentable {
    var fraction: Double
    let minimumFraction: Double
    var colors: [Color] = [AppTheme.accentCyan, AppTheme.accentBlue]
    var startPoint: UnitPoint = .leading
    var endPoint: UnitPoint = .trailing
    var animationDuration: TimeInterval = 0.2

    func makeNSView(context: Context) -> SmoothRateFillLayerView {
        let view = SmoothRateFillLayerView()
        view.update(
            fraction: fraction,
            minimumFraction: minimumFraction,
            colors: colors,
            startPoint: startPoint,
            endPoint: endPoint,
            animationDuration: animationDuration,
            animated: false
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
            animated: true
        )
    }
}

final class SmoothRateFillLayerView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var fraction: Double = 0
    private var minimumFraction: Double = 0
    private var fillColors: [Color] = []
    private var gradientStartPoint = UnitPoint.leading
    private var gradientEndPoint = UnitPoint.trailing
    private var animationDuration: TimeInterval = 0.2
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

    func update(
        fraction: Double,
        minimumFraction: Double,
        colors: [Color],
        startPoint: UnitPoint,
        endPoint: UnitPoint,
        animationDuration: TimeInterval,
        animated: Bool
    ) {
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

        guard animated,
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
        gradientLayer.contentsScale = scale
        gradientLayer.colors = fillColors.map { color in
            nsColor(from: color).cgColor
        }
        gradientLayer.startPoint = CGPoint(x: gradientStartPoint.x, y: gradientStartPoint.y)
        gradientLayer.endPoint = CGPoint(x: gradientEndPoint.x, y: gradientEndPoint.y)
    }

    private func nsColor(from color: Color) -> NSColor {
        let nsColor = NSColor(color)
        return nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    }
}
