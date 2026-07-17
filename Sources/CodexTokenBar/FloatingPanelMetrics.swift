import AppKit

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 258, height: 117)
    static let minimumControlSize = NSSize(width: 72, height: 34)
    static let baseCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let singleElementTopInset: CGFloat = 10
    static let rowSpacing: CGFloat = 2
    static let radarCrowdRowSpacing: CGFloat = 0
    static let rateRowHeight: CGFloat = 28
    static let usageStatusRowHeight: CGFloat = 20
    static let metricRowHeight: CGFloat = 11
    static let quotaRowHeight: CGFloat = 15.5
    static let radarRowHeight: CGFloat = 24
    static let crowdRadarRowHeight: CGFloat = 20
    static let metricOutset: CGFloat = 14.5
    static let metricTodayNudge: CGFloat = -4.5
    static let metricRequestsNudge: CGFloat = 8
    static let metricRequestsReferenceDigits = 3
    static let metricRequestsDigitCompensation: CGFloat = 2.8
    static let defaultScale = 1.0
    static let scaleRange = 0.75...2.0

    static func metricRequestsNudge(for requestCount: Int) -> CGFloat {
        let digits = max(1, String(abs(requestCount)).count)
        return metricRequestsNudge
            + CGFloat(metricRequestsReferenceDigits - digits) * metricRequestsDigitCompensation
    }

    static func metricTotalOffset(hasPreciseTokenUsage: Bool) -> CGFloat {
        hasPreciseTokenUsage ? -metricOutset : 0
    }

    static func metricTodayOffset(hasPreciseTokenUsage: Bool) -> CGFloat {
        hasPreciseTokenUsage ? metricTodayNudge : 0
    }

    static func metricRequestsOffset(requestCount: Int, hasPreciseTokenUsage: Bool) -> CGFloat {
        guard hasPreciseTokenUsage else { return 0 }
        return metricOutset + metricRequestsNudge(for: requestCount)
    }

    static func clampedScale(_ scale: Double) -> CGFloat {
        CGFloat(min(max(scale, scaleRange.lowerBound), scaleRange.upperBound))
    }

    static func size(scale: Double) -> NSSize {
        size(scale: scale, visibility: .default)
    }

    static func size(scale: Double, visibility: FloatingPanelContentVisibility) -> NSSize {
        size(effectiveScale: clampedScale(scale), visibility: visibility)
    }

    fileprivate static func size(effectiveScale: CGFloat, visibility: FloatingPanelContentVisibility) -> NSSize {
        let unscaled = unscaledSize(visibility: visibility)
        return NSSize(
            width: ceil(unscaled.width * effectiveScale),
            height: ceil(unscaled.height * effectiveScale)
        )
    }

    static func contentHeight(visibility: FloatingPanelContentVisibility) -> CGFloat {
        let groups = visibility.layoutGroups
        guard !groups.isEmpty else { return 0 }
        let rowHeights = groups.reduce(CGFloat.zero) { partial, group in
            partial + rowHeight(for: group)
        }
        let interRowSpacing = zip(groups, groups.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + spacing(between: pair.0, and: pair.1)
        }
        return rowHeights + interRowSpacing
    }

    static func spacing(
        between upperGroup: FloatingPanelContentGroup,
        and lowerGroup: FloatingPanelContentGroup
    ) -> CGFloat {
        if upperGroup == .radar, lowerGroup == .crowdRadar {
            return radarCrowdRowSpacing
        }
        return rowSpacing
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
        case .crowdRadar:
            return crowdRadarRowHeight
        }
    }

    static func rowWidth(for group: FloatingPanelContentGroup) -> CGFloat {
        switch group {
        case .rateAndBar, .quota, .radar, .crowdRadar:
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

struct FloatingTokenPanelScale: Equatable {
    let value: CGFloat

    init(baseScale: Double, interfaceScale: CGFloat) {
        value = FloatingTokenPanelMetrics.clampedScale(baseScale * Double(interfaceScale))
    }
}

struct FloatingTokenPanelLayout: Equatable {
    let effectiveScale: CGFloat
    let size: NSSize
    let cornerRadius: CGFloat

    init(scale: FloatingTokenPanelScale, visibility: FloatingPanelContentVisibility) {
        effectiveScale = scale.value
        size = FloatingTokenPanelMetrics.size(
            effectiveScale: scale.value,
            visibility: visibility
        )
        cornerRadius = FloatingTokenPanelMetrics.baseCornerRadius * scale.value
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
