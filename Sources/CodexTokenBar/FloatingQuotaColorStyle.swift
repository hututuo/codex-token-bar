import SwiftUI

enum FloatingQuotaColorMode: String, CaseIterable, Identifiable {
    case adaptive
    case fixed
    case panelGradient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive:
            return "随百分比"
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

    func fillStyle(remainingPercent: Double) -> AnyShapeStyle {
        switch mode {
        case .adaptive:
            return AnyShapeStyle(AppTheme.quotaRemainingColor(percent: remainingPercent))
        case .fixed:
            return AnyShapeStyle(resolvedFixedColor)
        case .panelGradient:
            return gradientAppearance.gradientShapeStyle
        }
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
