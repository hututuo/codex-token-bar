import AppKit

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 258, height: 88)
    static let baseCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let defaultScale = 1.0
    static let scaleRange = 0.75...2.0

    static func clampedScale(_ scale: Double) -> CGFloat {
        CGFloat(min(max(scale, scaleRange.lowerBound), scaleRange.upperBound))
    }

    static func size(scale: Double) -> NSSize {
        let clamped = clampedScale(scale)
        return NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
    }

    static func cornerRadius(scale: Double) -> CGFloat {
        baseCornerRadius * clampedScale(scale)
    }
}

enum FloatingPanelColorTools {
    private static let fallbackBlue = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1.0)

    static func deviceRGB(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB)
            ?? color.usingColorSpace(.sRGB)
            ?? fallbackBlue
    }
}
