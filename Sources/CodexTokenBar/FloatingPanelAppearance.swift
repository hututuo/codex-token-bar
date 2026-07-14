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

struct FloatingPanelBackgroundSample: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    var perceivedLuminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var relativeLuminance: Double {
        0.2126 * Self.linearized(red) + 0.7152 * Self.linearized(green) + 0.0722 * Self.linearized(blue)
    }

    var saturation: Double {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        guard maxValue > 0 else { return 0 }
        return (maxValue - minValue) / maxValue
    }

    var brightness: Double {
        max(red, green, blue)
    }

    var adaptiveDarkness: Double {
        let darkness = 1 - perceivedLuminance
        let saturatedColorBoost = saturation
            * 0.28
            * Self.smoothStep(edge0: 0.20, edge1: 0.70, value: darkness + (1 - brightness) * 0.22)
        return Self.clamp(darkness + saturatedColorBoost)
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge0 != edge1 else {
            return value < edge0 ? 0 : 1
        }
        let progress = clamp((value - edge0) / (edge1 - edge0))
        return progress * progress * (3 - 2 * progress)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct FloatingPanelTextPaletteSet: Equatable {
    let controlPalette: FloatingPanelReadableTextPalette
    let rowPalettes: [FloatingPanelContentGroup: FloatingPanelReadableTextPalette]
    let metricPalettes: [FloatingPanelMetricTextRegion: FloatingPanelReadableTextPalette]
    let embeddedUsageStatusPalette: FloatingPanelReadableTextPalette?
    let standaloneUsageStatusPalette: FloatingPanelReadableTextPalette?
    let radarActionPalette: FloatingPanelReadableTextPalette?
    let radarModelPalette: FloatingPanelReadableTextPalette?

    func harmonizedForUnifiedAutomaticTone() -> FloatingPanelTextPaletteSet {
        var rowPalettes = rowPalettes
        var metricPalettes = metricPalettes
        var embeddedUsageStatusPalette = embeddedUsageStatusPalette
        var standaloneUsageStatusPalette = standaloneUsageStatusPalette
        var radarActionPalette = radarActionPalette
        var radarModelPalette = radarModelPalette

        let slots: [FloatingPanelTextPaletteSlot] = [
            rowPalettes[.rateAndBar].map { _ in .row(.rateAndBar) },
            embeddedUsageStatusPalette.map { _ in .embeddedUsageStatus },
            standaloneUsageStatusPalette.map { _ in .standaloneUsageStatus },
        ].compactMap(\.self)
            + FloatingPanelMetricTextRegion.allCases.compactMap { region in
                metricPalettes[region].map { _ in .metric(region) }
            }
            + [
                radarActionPalette.map { _ in .radarAction },
                radarModelPalette.map { _ in .radarModel },
            ].compactMap(\.self)

        guard slots.count > 1 else { return self }

        func palette(for slot: FloatingPanelTextPaletteSlot) -> FloatingPanelReadableTextPalette? {
            switch slot {
            case .row(let group):
                return rowPalettes[group]
            case .metric(let region):
                return metricPalettes[region]
            case .embeddedUsageStatus:
                return embeddedUsageStatusPalette
            case .standaloneUsageStatus:
                return standaloneUsageStatusPalette
            case .radarAction:
                return radarActionPalette
            case .radarModel:
                return radarModelPalette
            }
        }

        let whiteSlots = slots.filter { slot in
            palette(for: slot)?.usesAutomaticWhiteFamily == true
        }
        guard whiteSlots.count == 1,
              let isolatedSlot = whiteSlots.first,
              let isolatedPalette = palette(for: isolatedSlot),
              isolatedPalette.isNearAutomaticWhiteFamilyBoundary
        else {
            return self
        }

        let snappedPalette = isolatedPalette.snappedBackFromIsolatedWhite()
        switch isolatedSlot {
        case .row(let group):
            rowPalettes[group] = snappedPalette
        case .metric(let region):
            metricPalettes[region] = snappedPalette
        case .embeddedUsageStatus:
            embeddedUsageStatusPalette = snappedPalette
        case .standaloneUsageStatus:
            standaloneUsageStatusPalette = snappedPalette
        case .radarAction:
            radarActionPalette = snappedPalette
        case .radarModel:
            radarModelPalette = snappedPalette
        }

        return FloatingPanelTextPaletteSet(
            controlPalette: controlPalette,
            rowPalettes: rowPalettes,
            metricPalettes: metricPalettes,
            embeddedUsageStatusPalette: embeddedUsageStatusPalette,
            standaloneUsageStatusPalette: standaloneUsageStatusPalette,
            radarActionPalette: radarActionPalette,
            radarModelPalette: radarModelPalette
        )
    }
}

private enum FloatingPanelTextPaletteSlot {
    case row(FloatingPanelContentGroup)
    case metric(FloatingPanelMetricTextRegion)
    case embeddedUsageStatus
    case standaloneUsageStatus
    case radarAction
    case radarModel
}

enum FloatingPanelMetricTextRegion: String, CaseIterable, Sendable {
    case total
    case today
    case requests
}

struct FloatingPanelTextTonePreference: Equatable, Sendable {
    let automaticStrength: Double
    let manualWhite: Double?

    static func mode(for sliderValue: Double) -> FloatingPanelTextTonePreference {
        let clamped = min(max(sliderValue, -1), 1)
        if clamped < 0 {
            return FloatingPanelTextTonePreference(
                automaticStrength: abs(clamped),
                manualWhite: nil
            )
        }
        return FloatingPanelTextTonePreference(
            automaticStrength: 1,
            manualWhite: clamped
        )
    }

    static func displayText(for sliderValue: Double) -> String {
        let clamped = min(max(sliderValue, -1), 1)
        let percent = Int((abs(clamped) * 100).rounded())
        return clamped < 0 ? "自动 \(percent)%" : "手动 \(percent)%"
    }
}

struct FloatingPanelReadableTextPalette: Equatable, Sendable {
    let backgroundLuminance: Double
    let fixedWhite: Double?
    let automaticStrength: Double

    init(backgroundLuminance: Double, automaticStrength: Double = 1) {
        self.backgroundLuminance = min(max(backgroundLuminance, 0), 1)
        fixedWhite = nil
        self.automaticStrength = min(max(automaticStrength, 0), 1)
    }

    init(fixedWhite: Double) {
        backgroundLuminance = 0.5
        self.fixedWhite = min(max(fixedWhite, 0), 1)
        automaticStrength = 1
    }

    init(backgroundSamples: [FloatingPanelBackgroundSample], automaticStrength: Double = 1) {
        let samples = backgroundSamples.isEmpty
            ? [FloatingPanelBackgroundSample(red: 0.86, green: 0.93, blue: 1.0)]
            : backgroundSamples
        let darknessValues = samples.map(\.adaptiveDarkness).sorted()
        let averageDarkness = darknessValues.reduce(0, +) / Double(darknessValues.count)
        let upperDarkness = Self.percentile(0.72, in: darknessValues)
        let contrastWhite = samples.map { 1.05 / ($0.relativeLuminance + 0.05) }.reduce(0, +) / Double(samples.count)
        let contrastBlack = samples.map { ($0.relativeLuminance + 0.05) / 0.05 }.reduce(0, +) / Double(samples.count)
        let whiteContrastHelp = Self.smoothStep(edge0: -0.26, edge1: 0.32, value: log(contrastWhite / max(contrastBlack, 0.001)))
        let visualDarkness = min(max(averageDarkness * 0.58 + upperDarkness * 0.42, 0), 1)
        let contrastAdjustedDarkness = min(max(visualDarkness * 0.82 + whiteContrastHelp * 0.18, 0), 1)
        backgroundLuminance = 1 - contrastAdjustedDarkness
        fixedWhite = nil
        self.automaticStrength = min(max(automaticStrength, 0), 1)
    }

    var primaryWhite: Double {
        if let fixedWhite {
            return fixedWhite
        }
        return foregroundWhite(lightValue: 0.00, grayValue: 0.15, darkValue: 1.00)
    }

    var secondaryWhite: Double {
        if let fixedWhite {
            return fixedWhite
        }
        return foregroundWhite(lightValue: 0.08, grayValue: 0.23, darkValue: 0.92)
    }

    var mutedWhite: Double {
        if let fixedWhite {
            return fixedWhite
        }
        return foregroundWhite(lightValue: 0.12, grayValue: 0.27, darkValue: 0.86)
    }

    var dividerWhite: Double {
        if let fixedWhite {
            return fixedWhite
        }
        return foregroundWhite(lightValue: 0.06, grayValue: 0.20, darkValue: 0.82)
    }

    var primaryColor: Color {
        Color(white: primaryWhite, opacity: 0.96)
    }

    var secondaryColor: Color {
        Color(white: secondaryWhite, opacity: 0.88)
    }

    var mutedColor: Color {
        Color(white: mutedWhite, opacity: 0.76)
    }

    var dividerColor: Color {
        Color(white: dividerWhite, opacity: 0.34)
    }

    private func foregroundWhite(lightValue: Double, grayValue: Double, darkValue: Double) -> Double {
        let darkness = automaticDarkness
        let blackFamilyProgress = smoothStep(edge0: 0.22, edge1: 0.44, value: darkness)
        let whiteFamilyProgress = smoothStep(edge0: 0.50, edge1: 0.78, value: darkness)
        let familySwitch = usesAutomaticWhiteFamily ? 1.0 : 0.0
        let blackFamily = mix(lightValue, grayValue, blackFamilyProgress)
        let whiteFamily = mix(max(0.78, darkValue - 0.07), min(darkValue, 1), whiteFamilyProgress)
        let fullValue = mix(blackFamily, whiteFamily, familySwitch)
        return min(max(applyAutomaticStrength(to: fullValue), 0), 1)
    }

    private var automaticDarkness: Double {
        1 - backgroundLuminance
    }

    fileprivate var usesAutomaticWhiteFamily: Bool {
        fixedWhite == nil && automaticDarkness >= Self.whiteFamilySwitchDarkness
    }

    fileprivate var isNearAutomaticWhiteFamilyBoundary: Bool {
        usesAutomaticWhiteFamily && automaticDarkness <= Self.isolatedWhiteSnapBackMaxDarkness
    }

    fileprivate func snappedBackFromIsolatedWhite() -> FloatingPanelReadableTextPalette {
        FloatingPanelReadableTextPalette(
            backgroundLuminance: 1 - Self.isolatedWhiteSnapBackTargetDarkness,
            automaticStrength: automaticStrength
        )
    }

    private static let whiteFamilySwitchDarkness = 0.455
    private static let isolatedWhiteSnapBackMaxDarkness = 0.51
    private static let isolatedWhiteSnapBackTargetDarkness = 0.44

    private func applyAutomaticStrength(to value: Double) -> Double {
        let strength = min(max(automaticStrength, 0), 1)
        if value < 0.5 {
            return mix(0.18, value, strength)
        }
        return mix(0.82, value, strength)
    }

    private func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge0 != edge1 else {
            return value < edge0 ? 0 : 1
        }
        let progress = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge0 != edge1 else {
            return value < edge0 ? 0 : 1
        }
        let progress = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    private static func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let clampedPercentile = min(max(percentile, 0), 1)
        let position = clampedPercentile * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(sortedValues.count - 1, lowerIndex + 1)
        let progress = position - Double(lowerIndex)
        return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * progress
    }
}

struct FloatingPanelAppearance: Equatable {
    static let startHexKey = "floatingPanelGradientStartHex"
    static let endHexKey = "floatingPanelGradientEndHex"
    static let directionKey = "floatingPanelGradientDirection"
    static let styleKey = "floatingPanelGradientStyle"
    static let unreadEffectKey = "floatingPanelUnreadEffect"
    static let unreadPreviewUntilKey = "floatingPanelUnreadPreviewUntil"
    static let textWhiteOverrideKey = "floatingPanelTextWhiteOverrideV2"

    static let defaultStartHex = "#FAF9FF"
    static let defaultEndHex = "#00C2EF"
    static let defaultDirection = FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue
    static let defaultStyle = FloatingPanelGradientStyle.linear.rawValue
    static let defaultUnreadEffect = FloatingPanelUnreadEffect.ripple.rawValue
    static let defaultTextWhiteOverride = -1.0
    private static let textPaletteCache = FloatingPanelTextPaletteCache()

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

    var readableTextPalette: FloatingPanelReadableTextPalette {
        FloatingPanelReadableTextPalette(backgroundLuminance: averagedRGB.luminance)
    }

    func textPalettes(
        panelSize: NSSize,
        scale: CGFloat,
        opacity: Double = 0.88,
        automaticStrength: Double = 1,
        visibility: FloatingPanelContentVisibility,
        hasPreciseTokenUsage: Bool = true
    ) -> FloatingPanelTextPaletteSet {
        let cacheKey = FloatingPanelTextPaletteCacheKey(
            appearance: self,
            panelSize: panelSize,
            scale: scale,
            opacity: opacity,
            automaticStrength: automaticStrength,
            visibility: visibility,
            hasPreciseTokenUsage: hasPreciseTokenUsage
        )
        if let cached = Self.textPaletteCache.value(for: cacheKey) {
            return cached
        }

        let panelRect = CGRect(
            x: 0,
            y: 0,
            width: max(1, panelSize.width),
            height: max(1, panelSize.height)
        )
        let controlRect = CGRect(
            x: 0,
            y: 0,
            width: panelRect.width,
            height: min(panelRect.height, max(20, 24 * max(scale, 0.1)))
        )
        let rows = rowRects(
            panelSize: panelRect.size,
            scale: scale,
            visibility: visibility
        )
        let rowPalettes = Dictionary(uniqueKeysWithValues: rows.map { group, rect in
            (group, palette(in: rect, panelSize: panelRect.size, opacity: opacity, automaticStrength: automaticStrength))
        })
        let radarRegionPalettes = rows
            .first { group, _ in group == .radar }
            .map { _, rect in
                radarPalettes(in: rect, panelSize: panelRect.size, scale: scale, opacity: opacity, automaticStrength: automaticStrength)
            }
        let metricRegionPalettes = rows
            .first { group, _ in group == .metrics }
            .map { _, rect in
                metricPalettes(
                    in: rect,
                    panelSize: panelRect.size,
                    scale: scale,
                    opacity: opacity,
                    automaticStrength: automaticStrength,
                    hasPreciseTokenUsage: hasPreciseTokenUsage
                )
            } ?? [:]
        let embeddedStatusPalette: FloatingPanelReadableTextPalette?
        if visibility.embedsUsageStatusInRateRow,
           let rateRow = rows.first(where: { group, _ in group == .rateAndBar }) {
            embeddedStatusPalette = embeddedUsageStatusTextPalette(
                in: rateRow.1,
                panelSize: panelRect.size,
                scale: scale,
                opacity: opacity,
                automaticStrength: automaticStrength
            )
        } else {
            embeddedStatusPalette = nil
        }
        let standaloneStatusPalette = rows
            .first { group, _ in group == .usageStatus }
            .map { _, rect in
                standaloneUsageStatusTextPalette(in: rect, panelSize: panelRect.size, scale: scale, opacity: opacity, automaticStrength: automaticStrength)
            }
        let result = FloatingPanelTextPaletteSet(
            controlPalette: palette(in: controlRect, panelSize: panelRect.size, opacity: opacity, automaticStrength: automaticStrength),
            rowPalettes: rowPalettes,
            metricPalettes: metricRegionPalettes,
            embeddedUsageStatusPalette: embeddedStatusPalette,
            standaloneUsageStatusPalette: standaloneStatusPalette,
            radarActionPalette: radarRegionPalettes?.action,
            radarModelPalette: radarRegionPalettes?.model
        ).harmonizedForUnifiedAutomaticTone()
        Self.textPaletteCache.store(result, for: cacheKey)
        return result
    }

    static func resetTextPaletteCacheForTesting() {
        textPaletteCache.reset()
    }

    static func textPaletteCacheMissCountForTesting() -> Int {
        textPaletteCache.missCount
    }

    private var averagedRGB: FloatingPanelRGB {
        let start = startRGB
        let end = endRGB
        return FloatingPanelRGB(
            red: (start.red + end.red) / 2,
            green: (start.green + end.green) / 2,
            blue: (start.blue + end.blue) / 2
        )
    }

    private var startRGB: FloatingPanelRGB {
        FloatingPanelRGB(hex: startHex) ?? FloatingPanelRGB(hex: Self.defaultStartHex) ?? .fallback
    }

    private var endRGB: FloatingPanelRGB {
        FloatingPanelRGB(hex: endHex) ?? FloatingPanelRGB(hex: Self.defaultEndHex) ?? .fallback
    }

    private var unreadIndicatorRGB: FloatingPanelRGB {
        averagedRGB.deepenedGlassAccent
    }

    private func rowRects(
        panelSize: CGSize,
        scale: CGFloat,
        visibility: FloatingPanelContentVisibility
    ) -> [(FloatingPanelContentGroup, CGRect)] {
        let groups = visibility.layoutGroups
        guard !groups.isEmpty else { return [] }

        let scale = max(scale, 0.1)
        let horizontalPadding = FloatingTokenPanelMetrics.horizontalPadding * scale
        let verticalPadding = FloatingTokenPanelMetrics.verticalPadding * scale
        let rowSpacing = FloatingTokenPanelMetrics.rowSpacing * scale
        let topInset = visibility.needsTopControlInset
            ? FloatingTokenPanelMetrics.singleElementTopInset * scale
            : 0
        let contentHeight = FloatingTokenPanelMetrics.contentHeight(visibility: visibility) * scale
        let cardWidth = max(0, panelSize.width - horizontalPadding * 2)
        let cardHeight = max(0, panelSize.height - verticalPadding * 2)
        let contentAreaHeight = max(0, cardHeight - topInset)
        var y = verticalPadding + topInset + max(0, (contentAreaHeight - contentHeight) / 2)

        return groups.map { group in
            let height = FloatingTokenPanelMetrics.rowHeight(for: group) * scale
            defer { y += height + rowSpacing }
            return (
                group,
                CGRect(
                    x: horizontalPadding,
                    y: y,
                    width: cardWidth,
                    height: height
                )
            )
        }
    }

    private func palette(
        in rect: CGRect,
        panelSize: CGSize,
        opacity: Double,
        automaticStrength: Double
    ) -> FloatingPanelReadableTextPalette {
        FloatingPanelReadableTextPalette(
            backgroundSamples: backgroundSamples(in: rect, panelSize: panelSize, opacity: opacity),
            automaticStrength: automaticStrength
        )
    }

    private func radarPalettes(
        in rect: CGRect,
        panelSize: CGSize,
        scale: CGFloat,
        opacity: Double,
        automaticStrength: Double
    ) -> (action: FloatingPanelReadableTextPalette, model: FloatingPanelReadableTextPalette) {
        let scale = max(scale, 0.1)
        let spacing = 7 * scale
        let dividerWidth = 1 * scale
        let columnWidth = max(1, (rect.width - spacing * 2 - dividerWidth) / 2)
        let actionRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: columnWidth,
            height: rect.height
        )
        let modelRect = CGRect(
            x: rect.maxX - columnWidth,
            y: rect.minY,
            width: columnWidth,
            height: rect.height
        )
        return (
            action: palette(in: actionRect, panelSize: panelSize, opacity: opacity, automaticStrength: automaticStrength),
            model: palette(in: modelRect, panelSize: panelSize, opacity: opacity, automaticStrength: automaticStrength)
        )
    }

    private func metricPalettes(
        in rect: CGRect,
        panelSize: CGSize,
        scale: CGFloat,
        opacity: Double,
        automaticStrength: Double,
        hasPreciseTokenUsage: Bool
    ) -> [FloatingPanelMetricTextRegion: FloatingPanelReadableTextPalette] {
        let scale = max(scale, 0.1)
        let spacing = 6 * scale
        let slotWidth = max(1, (rect.width - spacing * 2) / 3)
        let offsets: [FloatingPanelMetricTextRegion: CGFloat] = [
            .total: FloatingTokenPanelMetrics.metricTotalOffset(
                hasPreciseTokenUsage: hasPreciseTokenUsage
            ) * scale,
            .today: FloatingTokenPanelMetrics.metricTodayOffset(
                hasPreciseTokenUsage: hasPreciseTokenUsage
            ) * scale,
            .requests: FloatingTokenPanelMetrics.metricRequestsOffset(
                requestCount: 100,
                hasPreciseTokenUsage: hasPreciseTokenUsage
            ) * scale,
        ]
        return Dictionary(uniqueKeysWithValues: FloatingPanelMetricTextRegion.allCases.enumerated().map { index, region in
            let slotX = rect.minX + CGFloat(index) * (slotWidth + spacing)
            let offset = offsets[region] ?? 0
            let regionRect = clampedRect(
                CGRect(
                    x: slotX + offset,
                    y: rect.minY,
                    width: slotWidth,
                    height: rect.height
                ),
                inside: rect
            )
            return (
                region,
                palette(in: regionRect, panelSize: panelSize, opacity: opacity, automaticStrength: automaticStrength)
            )
        })
    }

    private func embeddedUsageStatusTextPalette(
        in rect: CGRect,
        panelSize: CGSize,
        scale: CGFloat,
        opacity: Double,
        automaticStrength: Double
    ) -> FloatingPanelReadableTextPalette {
        let scale = max(scale, 0.1)
        let leftRateBlockWidth = min(rect.width - 1, max(82 * scale, rect.width * 0.38))
        let statusRect = CGRect(
            x: rect.minX + leftRateBlockWidth,
            y: rect.minY,
            width: max(1, rect.width - leftRateBlockWidth),
            height: min(rect.height, 13 * scale)
        )
        return palette(
            in: clampedRect(statusRect, inside: rect),
            panelSize: panelSize,
            opacity: opacity,
            automaticStrength: automaticStrength
        )
    }

    private func standaloneUsageStatusTextPalette(
        in rect: CGRect,
        panelSize: CGSize,
        scale: CGFloat,
        opacity: Double,
        automaticStrength: Double
    ) -> FloatingPanelReadableTextPalette {
        let scale = max(scale, 0.1)
        let textWidth = min(rect.width, FloatingTokenPanelMetrics.rowWidth(for: .usageStatus) * scale)
        let statusRect = CGRect(
            x: rect.midX - textWidth / 2,
            y: rect.minY,
            width: max(1, textWidth),
            height: rect.height
        )
        return palette(
            in: clampedRect(statusRect, inside: rect),
            panelSize: panelSize,
            opacity: opacity,
            automaticStrength: automaticStrength
        )
    }

    private func clampedRect(_ candidate: CGRect, inside bounds: CGRect) -> CGRect {
        let minX = min(max(candidate.minX, bounds.minX), max(bounds.minX, bounds.maxX - 1))
        let minY = min(max(candidate.minY, bounds.minY), max(bounds.minY, bounds.maxY - 1))
        let maxX = min(max(candidate.maxX, minX + 1), bounds.maxX)
        let maxY = min(max(candidate.maxY, minY + 1), bounds.maxY)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func backgroundSamples(in rect: CGRect, panelSize: CGSize, opacity: Double) -> [FloatingPanelBackgroundSample] {
        let xFactors: [CGFloat] = [0.18, 0.50, 0.82]
        let yFactors: [CGFloat] = [0.24, 0.50, 0.76]
        return xFactors.flatMap { xFactor in
            yFactors.map { yFactor in
                let x = min(max((rect.minX + rect.width * xFactor) / max(panelSize.width, 1), 0), 1)
                let y = min(max((rect.minY + rect.height * yFactor) / max(panelSize.height, 1), 0), 1)
                let rgb = visibleBackgroundRGB(at: CGPoint(x: x, y: y), opacity: opacity)
                return FloatingPanelBackgroundSample(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
        }
    }

    private func visibleBackgroundRGB(at normalizedPoint: CGPoint, opacity: Double) -> FloatingPanelRGB {
        let gradientOpacity = min(0.96, max(0.62, opacity + 0.04))
        let gradient = gradientRGB(at: normalizedPoint)
        let glassBase = endRGB.mixed(with: gradient, progress: gradientOpacity)
        let sheenProgress = min(max((normalizedPoint.x + normalizedPoint.y) / 2, 0), 1)
        let sheenOpacity = 0.16 + (0.02 - 0.16) * Double(sheenProgress)
        return glassBase.mixed(with: .white, progress: sheenOpacity)
    }

    private func gradientRGB(at normalizedPoint: CGPoint) -> FloatingPanelRGB {
        startRGB.mixed(with: endRGB, progress: gradientProgress(at: normalizedPoint))
    }

    private func gradientProgress(at normalizedPoint: CGPoint) -> Double {
        switch style {
        case .linear:
            return linearGradientProgress(at: normalizedPoint)
        case .radial:
            return radialGradientProgress(at: normalizedPoint)
        case .angular:
            return angularGradientProgress(at: normalizedPoint)
        }
    }

    private func linearGradientProgress(at point: CGPoint) -> Double {
        let start = direction.startPoint
        let end = direction.endPoint
        let startX = Double(start.x)
        let startY = Double(start.y)
        let vectorX = Double(end.x - start.x)
        let vectorY = Double(end.y - start.y)
        let lengthSquared = vectorX * vectorX + vectorY * vectorY
        guard lengthSquared > 0 else { return 0 }
        let projected = ((Double(point.x) - startX) * vectorX + (Double(point.y) - startY) * vectorY) / lengthSquared
        return min(max(projected, 0), 1)
    }

    private func radialGradientProgress(at point: CGPoint) -> Double {
        let center = CGPoint(x: direction.startPoint.x, y: direction.startPoint.y)
        let distance = hypot(point.x - center.x, point.y - center.y)
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
        ]
        let maxDistance = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 1
        return min(max(Double(distance / max(maxDistance, 0.001)), 0), 1)
    }

    private func angularGradientProgress(at point: CGPoint) -> Double {
        let angle = atan2(Double(point.y - 0.5), Double(point.x - 0.5))
        let normalizedAngle = (angle / (Double.pi * 2) + 1).truncatingRemainder(dividingBy: 1)
        let offset = direction == .bottomLeadingToTopTrailing ? 0.125 : 0
        let cycle = (normalizedAngle - offset + 1).truncatingRemainder(dividingBy: 1)
        return cycle <= 0.5 ? cycle * 2 : (1 - cycle) * 2
    }
}

private struct FloatingPanelRGB {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = FloatingPanelRGB(red: 0.86, green: 0.93, blue: 1.0)
    static let white = FloatingPanelRGB(red: 1, green: 1, blue: 1)

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

    func mixed(with other: FloatingPanelRGB, progress: Double) -> FloatingPanelRGB {
        let progress = min(max(progress, 0), 1)
        return FloatingPanelRGB(
            red: red + (other.red - red) * progress,
            green: green + (other.green - green) * progress,
            blue: blue + (other.blue - blue) * progress
        )
    }
}

private struct FloatingPanelTextPaletteCacheKey: Equatable {
    let startHex: String
    let endHex: String
    let directionRaw: String
    let styleRaw: String
    let panelWidth: Int
    let panelHeight: Int
    let scale: Int
    let opacity: Int
    let automaticStrength: Int
    let showRateAndBar: Bool
    let showUsageStatus: Bool
    let showMetrics: Bool
    let showQuota: Bool
    let showRadar: Bool
    let hasPreciseTokenUsage: Bool
    let groupOrder: [FloatingPanelContentGroup]

    init(
        appearance: FloatingPanelAppearance,
        panelSize: NSSize,
        scale: CGFloat,
        opacity: Double,
        automaticStrength: Double,
        visibility: FloatingPanelContentVisibility,
        hasPreciseTokenUsage: Bool
    ) {
        startHex = appearance.startHex
        endHex = appearance.endHex
        directionRaw = appearance.directionRaw
        styleRaw = appearance.styleRaw
        panelWidth = Self.quantize(panelSize.width)
        panelHeight = Self.quantize(panelSize.height)
        self.scale = Self.quantize(scale)
        self.opacity = Self.quantize(opacity)
        self.automaticStrength = Self.quantize(automaticStrength)
        showRateAndBar = visibility.showRateAndBar
        showUsageStatus = visibility.showUsageStatus
        showMetrics = visibility.showMetrics
        showQuota = visibility.showQuota
        showRadar = visibility.showRadar
        self.hasPreciseTokenUsage = hasPreciseTokenUsage
        groupOrder = visibility.groupOrder
    }

    private static func quantize(_ value: CGFloat) -> Int {
        Int((Double(value) * 1000).rounded())
    }

    private static func quantize(_ value: Double) -> Int {
        Int((value * 1000).rounded())
    }
}

private final class FloatingPanelTextPaletteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (key: FloatingPanelTextPaletteCacheKey, value: FloatingPanelTextPaletteSet)?
    private var misses = 0

    var missCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return misses
    }

    func value(for key: FloatingPanelTextPaletteCacheKey) -> FloatingPanelTextPaletteSet? {
        lock.lock()
        defer { lock.unlock() }
        guard entry?.key == key else { return nil }
        return entry?.value
    }

    func store(_ value: FloatingPanelTextPaletteSet, for key: FloatingPanelTextPaletteCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        misses += 1
        entry = (key, value)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        misses = 0
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
