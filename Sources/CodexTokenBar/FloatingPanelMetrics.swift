import AppKit

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 258, height: 112)
    static let minimumControlSize = NSSize(width: 72, height: 34)
    static let baseCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let singleElementTopInset: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let rateRowHeight: CGFloat = 30
    static let usageStatusRowHeight: CGFloat = 11
    static let metricRowHeight: CGFloat = 13
    static let quotaRowHeight: CGFloat = 16.5
    static let radarRowHeight: CGFloat = 26
    static let metricOutset: CGFloat = 9
    static let defaultScale = 1.0
    static let scaleRange = 0.75...2.0

    static func clampedScale(_ scale: Double) -> CGFloat {
        CGFloat(min(max(scale, scaleRange.lowerBound), scaleRange.upperBound))
    }

    static func size(scale: Double) -> NSSize {
        size(scale: scale, visibility: .default)
    }

    static func size(scale: Double, visibility: FloatingPanelContentVisibility) -> NSSize {
        let clamped = clampedScale(scale)
        let unscaled = unscaledSize(visibility: visibility)
        return NSSize(width: ceil(unscaled.width * clamped), height: ceil(unscaled.height * clamped))
    }

    static func contentHeight(visibility: FloatingPanelContentVisibility) -> CGFloat {
        let groups = visibility.layoutGroups
        guard !groups.isEmpty else { return 0 }
        let rowHeights = groups.reduce(CGFloat.zero) { partial, group in
            partial + rowHeight(for: group)
        }
        return rowHeights + rowSpacing * CGFloat(max(groups.count - 1, 0))
    }

    static func rowHeight(for group: FloatingPanelContentGroup) -> CGFloat {
        switch group {
        case .rateAndBar:
            return rateRowHeight
        case .usageStatus:
            return usageStatusRowHeight
        case .metrics:
            return metricRowHeight
        case .quota:
            return quotaRowHeight
        case .radar:
            return radarRowHeight
        }
    }

    static func rowWidth(for group: FloatingPanelContentGroup) -> CGFloat {
        switch group {
        case .rateAndBar, .quota, .radar:
            return baseSize.width - horizontalPadding * 2
        case .usageStatus:
            return 174
        case .metrics:
            return 218
        }
    }

    private static func unscaledSize(visibility: FloatingPanelContentVisibility) -> NSSize {
        let groups = visibility.layoutGroups
        guard !groups.isEmpty else { return minimumControlSize }

        let contentWidth = groups.map(rowWidth(for:)).max() ?? 0
        let width = max(minimumControlSize.width, horizontalPadding * 2 + contentWidth)
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let computedHeight = max(minimumControlSize.height, verticalPadding * 2 + topInset + contentHeight(visibility: visibility))
        let height = visibility == .default ? baseSize.height : computedHeight
        return NSSize(width: width, height: height)
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
