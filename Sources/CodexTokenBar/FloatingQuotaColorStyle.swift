import SwiftUI

enum FloatingQuotaColorMode: String, CaseIterable, Identifiable {
    case adaptive
    case fixed
    case panelGradient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive:
            return "随均速"
        case .fixed:
            return "固定色"
        case .panelGradient:
            return "面板渐变"
        }
    }
}

struct FloatingQuotaColorStyle {
    static let modeKey = "floatingQuotaColorMode"
    static let fixedHexKey = "floatingQuotaFixedHex"
    static let defaultMode = FloatingQuotaColorMode.adaptive.rawValue
    static let defaultFixedHex = "#1469CC"

    let modeRaw: String
    let fixedHex: String
    let gradientAppearance: FloatingPanelAppearance

    static var `default`: FloatingQuotaColorStyle {
        FloatingQuotaColorStyle(
            modeRaw: defaultMode,
            fixedHex: defaultFixedHex,
            gradientAppearance: .default
        )
    }

    var mode: FloatingQuotaColorMode {
        FloatingQuotaColorMode(rawValue: modeRaw) ?? .adaptive
    }

    var resolvedFixedColor: Color {
        Color(floatingPanelHex: fixedHex)
            ?? Color(floatingPanelHex: Self.defaultFixedHex)
            ?? AppTheme.accentBlue
    }

    func fillStyle(
        remainingPercent: Double,
        expectedRemainingPercent: Double?
    ) -> AnyShapeStyle {
        switch mode {
        case .adaptive:
            return AnyShapeStyle(
                AppTheme.quotaRemainingColor(
                    percent: Self.adaptiveMetricPercent(
                        remainingPercent: remainingPercent,
                        expectedRemainingPercent: expectedRemainingPercent
                    )
                )
            )
        case .fixed:
            return AnyShapeStyle(resolvedFixedColor)
        case .panelGradient:
            return gradientAppearance.gradientShapeStyle
        }
    }

    static func adaptiveMetricPercent(
        remainingPercent: Double,
        expectedRemainingPercent: Double?
    ) -> Double {
        guard remainingPercent.isFinite,
              let expectedRemainingPercent,
              expectedRemainingPercent.isFinite else {
            return 100
        }

        let remaining = min(100, max(0, remainingPercent))
        let expected = min(100, max(0, expectedRemainingPercent))
        let delta = remaining - expected
        let stops: [(delta: Double, metric: Double)] = [
            (-35, 0),
            (-20, 20),
            (-8, 35),
            (0, 70),
            (20, 100),
        ]

        if delta <= stops[0].delta { return stops[0].metric }
        if delta >= stops[stops.count - 1].delta { return stops[stops.count - 1].metric }

        guard let upperIndex = stops.firstIndex(where: { delta <= $0.delta }), upperIndex > 0 else {
            return stops[0].metric
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (delta - lower.delta) / (upper.delta - lower.delta)
        return lower.metric + (upper.metric - lower.metric) * progress
    }
}

extension FloatingPanelAppearance {
    var gradientShapeStyle: AnyShapeStyle {
        let colors = [startColor, endColor]
        switch style {
        case .linear:
            return AnyShapeStyle(
                LinearGradient(colors: colors, startPoint: direction.startPoint, endPoint: direction.endPoint)
            )
        case .radial:
            return AnyShapeStyle(
                RadialGradient(colors: colors, center: direction.startPoint, startRadius: 4, endRadius: 240)
            )
        case .angular:
            return AnyShapeStyle(
                AngularGradient(
                    colors: [startColor, endColor, startColor],
                    center: .center,
                    angle: .degrees(direction == .bottomLeadingToTopTrailing ? 45 : 0)
                )
            )
        }
    }
}
