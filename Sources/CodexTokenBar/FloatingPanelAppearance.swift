import AppKit
import SwiftUI

enum FloatingPanelGradientDirection: String, CaseIterable, Identifiable {
    case leadingToTrailing
    case topToBottom
    case topLeadingToBottomTrailing
    case bottomLeadingToTopTrailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leadingToTrailing:
            return "左到右"
        case .topToBottom:
            return "上到下"
        case .topLeadingToBottomTrailing:
            return "左上到右下"
        case .bottomLeadingToTopTrailing:
            return "左下到右上"
        }
    }

    var startPoint: UnitPoint {
        switch self {
        case .leadingToTrailing:
            return .leading
        case .topToBottom:
            return .top
        case .topLeadingToBottomTrailing:
            return .topLeading
        case .bottomLeadingToTopTrailing:
            return .bottomLeading
        }
    }

    var endPoint: UnitPoint {
        switch self {
        case .leadingToTrailing:
            return .trailing
        case .topToBottom:
            return .bottom
        case .topLeadingToBottomTrailing:
            return .bottomTrailing
        case .bottomLeadingToTopTrailing:
            return .topTrailing
        }
    }
}

enum FloatingPanelGradientStyle: String, CaseIterable, Identifiable {
    case linear
    case radial
    case angular

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear:
            return "线性"
        case .radial:
            return "径向"
        case .angular:
            return "环形"
        }
    }
}

enum FloatingPanelUnreadEffect: String, CaseIterable, Identifiable {
    case off
    case ripple
    case shimmer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "关"
        case .ripple:
            return "涟漪"
        case .shimmer:
            return "扫光"
        }
    }

    var helpText: String {
        switch self {
        case .off:
            return "关闭消息提醒背景效果"
        case .ripple:
            return "未读时显示边框回弹涟漪"
        case .shimmer:
            return "未读时显示柔和扫光"
        }
    }
}

enum FloatingPanelReadableTextTone: Equatable, Sendable {
    case darkText
    case lightText

    var primaryColor: Color {
        switch self {
        case .darkText:
            return Color.black.opacity(0.90)
        case .lightText:
            return Color.white.opacity(0.92)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .darkText:
            return Color.black.opacity(0.68)
        case .lightText:
            return Color.white.opacity(0.76)
        }
    }

    var mutedColor: Color {
        switch self {
        case .darkText:
            return Color.black.opacity(0.54)
        case .lightText:
            return Color.white.opacity(0.62)
        }
    }

    var dividerColor: Color {
        switch self {
        case .darkText:
            return Color.black.opacity(0.18)
        case .lightText:
            return Color.white.opacity(0.20)
        }
    }
}

struct FloatingPanelAppearance: Equatable {
    static let startHexKey = "floatingPanelGradientStartHex"
    static let endHexKey = "floatingPanelGradientEndHex"
    static let directionKey = "floatingPanelGradientDirection"
    static let styleKey = "floatingPanelGradientStyle"
    static let unreadEffectKey = "floatingPanelUnreadEffect"
    static let unreadPreviewUntilKey = "floatingPanelUnreadPreviewUntil"

    static let defaultStartHex = "#E6F4FF"
    static let defaultEndHex = "#D4E8FF"
    static let defaultDirection = FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue
    static let defaultStyle = FloatingPanelGradientStyle.linear.rawValue
    static let defaultUnreadEffect = FloatingPanelUnreadEffect.ripple.rawValue

    var startHex: String
    var endHex: String
    var directionRaw: String
    var styleRaw: String

    static var `default`: FloatingPanelAppearance {
        FloatingPanelAppearance(
            startHex: defaultStartHex,
            endHex: defaultEndHex,
            directionRaw: defaultDirection,
            styleRaw: defaultStyle
        )
    }

    var startColor: Color {
        Color(floatingPanelHex: startHex) ?? Color(floatingPanelHex: Self.defaultStartHex) ?? AppTheme.panelBackgroundAlt
    }

    var endColor: Color {
        Color(floatingPanelHex: endHex) ?? Color(floatingPanelHex: Self.defaultEndHex) ?? AppTheme.raisedBackground
    }

    var direction: FloatingPanelGradientDirection {
        FloatingPanelGradientDirection(rawValue: directionRaw) ?? FloatingPanelGradientDirection(rawValue: Self.defaultDirection) ?? .topLeadingToBottomTrailing
    }

    var style: FloatingPanelGradientStyle {
        FloatingPanelGradientStyle(rawValue: styleRaw) ?? FloatingPanelGradientStyle(rawValue: Self.defaultStyle) ?? .linear
    }

    var unreadIndicatorColor: Color {
        unreadIndicatorRGB.color
    }

    var unreadIndicatorStrokeColor: Color {
        if averagedRGB.luminance > 0.58 {
            return Color.white.opacity(0.68)
        }
        return Color.white.opacity(0.50)
    }

    var readableTextTone: FloatingPanelReadableTextTone {
        averagedRGB.luminance > 0.58 ? .darkText : .lightText
    }

    private var averagedRGB: FloatingPanelRGB {
        let start = FloatingPanelRGB(hex: startHex) ?? FloatingPanelRGB(hex: Self.defaultStartHex) ?? .fallback
        let end = FloatingPanelRGB(hex: endHex) ?? FloatingPanelRGB(hex: Self.defaultEndHex) ?? .fallback
        return FloatingPanelRGB(
            red: (start.red + end.red) / 2,
            green: (start.green + end.green) / 2,
            blue: (start.blue + end.blue) / 2
        )
    }

    private var unreadIndicatorRGB: FloatingPanelRGB {
        averagedRGB.deepenedGlassAccent
    }
}

private struct FloatingPanelRGB {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = FloatingPanelRGB(red: 0.86, green: 0.93, blue: 1.0)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }
        red = Double((value >> 16) & 0xff) / 255.0
        green = Double((value >> 8) & 0xff) / 255.0
        blue = Double(value & 0xff) / 255.0
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var deepenedGlassAccent: FloatingPanelRGB {
        let hsb = hsb
        let hue = hsb.saturation < 0.04 ? 0.58 : hsb.hue
        let saturation = min(0.92, max(0.54, hsb.saturation * 1.55 + 0.18))
        let brightness: Double
        if luminance > 0.78 {
            brightness = 0.76
        } else if luminance > 0.48 {
            brightness = min(0.84, max(0.62, hsb.brightness * 0.86))
        } else {
            brightness = min(0.96, max(0.68, hsb.brightness * 1.14))
        }
        return FloatingPanelRGB(hue: hue, saturation: saturation, brightness: brightness)
    }

    private var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        let brightness = maxValue
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxValue == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }
        return (hue < 0 ? hue + 1 : hue, saturation, brightness)
    }

    private init(hue: Double, saturation: Double, brightness: Double) {
        let hue = hue - floor(hue)
        let saturation = min(max(saturation, 0), 1)
        let brightness = min(max(brightness, 0), 1)
        let chroma = brightness * saturation
        let x = chroma * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let segment = Int((hue * 6).rounded(.down))
        let base: (Double, Double, Double)
        switch segment {
        case 0:
            base = (chroma, x, 0)
        case 1:
            base = (x, chroma, 0)
        case 2:
            base = (0, chroma, x)
        case 3:
            base = (0, x, chroma)
        case 4:
            base = (x, 0, chroma)
        default:
            base = (chroma, 0, x)
        }
        self.init(red: base.0 + m, green: base.1 + m, blue: base.2 + m)
    }

    func distance(to other: FloatingPanelRGB) -> Double {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue
        return (redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta).squareRoot()
    }
}

extension Color {
    init?(floatingPanelHex hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }

    func floatingPanelHexString() -> String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return nil
        }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
