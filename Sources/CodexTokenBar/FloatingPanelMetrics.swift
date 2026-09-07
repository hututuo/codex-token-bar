import AppKit

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 258, height: 120)
    static let minimumControlSize = NSSize(width: 72, height: 34)
    static let baseCornerRadius: CGFloat = 14
    // Together with uniform card scaling, this leaves approximately 5pt on each side.
    static let shellPadding: CGFloat = 2.5
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 5
    static let singleElementTopInset: CGFloat = 10
    static let rowSpacing: CGFloat = 1.5
    static let radarCrowdRowSpacing: CGFloat = 0
    // The live-rate strip carries the largest type and the optional status
    // line, but should not dominate the compact panel's vertical rhythm.
    static let rateRowHeight: CGFloat = 26
    static let usageStatusRowHeight: CGFloat = 20
    static let metricRowHeight: CGFloat = 13
    static let runningThreadsRowHeight: CGFloat = 14
    // The model cost/share strip is intentionally a compact 9pt content box;
    // the text is centered inside it by the paged row container.
    static let todayModelRowHeight: CGFloat = 9
    // Keep the visible quota bar and its row on the same compact 14pt track;
    // the surrounding panel still owns the larger click-safe surface.
    static let quotaBarHeight: CGFloat = 14
    static let quotaRowHeight: CGFloat = 14
    static let radarRowHeight: CGFloat = 23
    // Keep both radar rows on the same compact 23pt track. The crowd typography
    // is scaled from its former 20pt track so the two-line result remains
    // readable without restoring the old extra vertical whitespace.
    static let crowdRadarRowHeight: CGFloat = radarRowHeight
    static let crowdRadarTypographyScale: CGFloat = crowdRadarRowHeight / 20
    static let metricOutset: CGFloat = 14.5
    static let metricTodayNudge: CGFloat = -4.5
    static let metricRequestsNudge: CGFloat = 8
    static let metricRequestsReferenceDigits = 3
    static let metricRequestsDigitCompensation: CGFloat = 2.8
    // The paging guide temporarily expands the panel so its quota-pace
    // explainer remains readable instead of being clipped by the normal
    // compact floating surface.
    static let pagingGuideCalloutWidth: CGFloat = 220
    static let pagingGuideWindowWidth: CGFloat = 620
    // The guide card now sits below the normal panel. Keep only enough extra
    // height for that card instead of stretching the whole panel vertically.
    static let pagingGuideHeight: CGFloat = 240
    static let runningModelDetailsGap: CGFloat = 8
    static let runningModelDetailsWidth: CGFloat = 260
    static let runningModelDetailsTrailingInset: CGFloat = 0
    static let runningModelDetailsMinimumHeight: CGFloat = 96
    static let runningModelDetailsBaseHeight: CGFloat = 84
    static let runningModelDetailsRowHeight: CGFloat = 27
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

    static func size(
        scale: Double,
        visibility: FloatingPanelContentVisibility,
        pagingGuidePresented: Bool = false,
        runningModelDetailsPresented: Bool = false,
        runningModelDetailsRowUnits: Int = 0
    ) -> NSSize {
        size(
            effectiveScale: clampedScale(scale),
            visibility: visibility,
            pagingGuidePresented: pagingGuidePresented,
            runningModelDetailsPresented: runningModelDetailsPresented,
            runningModelDetailsRowUnits: runningModelDetailsRowUnits
        )
    }

    static func size(
        effectiveScale: CGFloat,
        visibility: FloatingPanelContentVisibility,
        pagingGuidePresented: Bool = false,
        runningModelDetailsPresented: Bool = false,
        runningModelDetailsRowUnits: Int = 0
    ) -> NSSize {
        let unscaled = unscaledSize(
            visibility: visibility,
            pagingGuidePresented: pagingGuidePresented,
            runningModelDetailsPresented: runningModelDetailsPresented,
            runningModelDetailsRowUnits: runningModelDetailsRowUnits
        )
        return NSSize(
            width: ceil(unscaled.width * effectiveScale),
            height: ceil(unscaled.height * effectiveScale)
        )
    }

    static func contentHeight(visibility: FloatingPanelContentVisibility) -> CGFloat {
        let rows = visibility.layoutRows
        guard !rows.isEmpty else { return 0 }
        let rowHeights = rows.reduce(CGFloat.zero) { partial, row in
            partial + (row.groups.map(rowHeight(for:)).max() ?? 0)
        }
        let interRowSpacing = zip(rows, rows.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + spacing(between: pair.0.primaryGroup, and: pair.1.primaryGroup)
        }
        return rowHeights + interRowSpacing
    }

    static func runningModelDetailsHeight(rowCount: Int) -> CGFloat {
        min(320, max(
            runningModelDetailsMinimumHeight,
            runningModelDetailsBaseHeight
                + CGFloat(max(1, rowCount)) * runningModelDetailsRowHeight
        ))
    }

    static func firstPagedRowCenterY(
        visibility: FloatingPanelContentVisibility,
        panelHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat? {
        pagedRowCenterYs(
            visibility: visibility,
            panelHeight: panelHeight,
            scale: scale
        ).first
    }

    static func pagedRowCenterYs(
        visibility: FloatingPanelContentVisibility,
        panelHeight: CGFloat,
        scale: CGFloat
    ) -> [CGFloat] {
        let rows = visibility.layoutRows
        guard rows.contains(where: { $0.isPaged || $0.groups.contains(.crowdRadar) }), scale > 0 else { return [] }

        let unscaledPanelHeight = panelHeight / scale
        let contentAreaHeight = max(0, unscaledPanelHeight - verticalPadding * 2)
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let centeredInset = max(0, contentAreaHeight - topInset - contentHeight(visibility: visibility)) / 2
        var cursor = verticalPadding + topInset + centeredInset

        var centers: [CGFloat] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                cursor += spacing(between: rows[index - 1].primaryGroup, and: row.primaryGroup)
            }
            let height = row.groups.map(rowHeight(for:)).max() ?? 0
            if row.isPaged || row.groups.contains(.crowdRadar) {
                centers.append((cursor + height / 2) * scale)
            }
            cursor += height
        }
        return centers
    }

    static func usageStatusRowCenterY(
        visibility: FloatingPanelContentVisibility,
        panelHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat? {
        let rows = visibility.layoutRows
        guard rows.contains(where: {
            $0.groups.contains(.usageStatus)
                || ($0.groups.contains(.rateAndBar) && visibility.embedsUsageStatusInRateRow)
        }), scale > 0 else { return nil }

        let unscaledPanelHeight = panelHeight / scale
        let contentAreaHeight = max(0, unscaledPanelHeight - verticalPadding * 2)
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let centeredInset = max(0, contentAreaHeight - topInset - contentHeight(visibility: visibility)) / 2
        var cursor = verticalPadding + topInset + centeredInset

        for (index, row) in rows.enumerated() {
            if index > 0 {
                cursor += spacing(between: rows[index - 1].primaryGroup, and: row.primaryGroup)
            }
            let height = row.groups.map(rowHeight(for:)).max() ?? 0
            if row.groups.contains(.usageStatus)
                || (row.groups.contains(.rateAndBar) && visibility.embedsUsageStatusInRateRow) {
                return (cursor + height / 2) * scale
            }
            cursor += height
        }
        return nil
    }

    static func runningThreadsRowCenterY(
        visibility: FloatingPanelContentVisibility,
        panelHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat? {
        let targetGroup: FloatingPanelContentGroup = visibility.embedsRunningThreadsInMetricsRow
            ? .metrics
            : .runningThreads
        let rows = visibility.layoutRows
        guard visibility.hasRunningThreadDetailsTarget, scale > 0 else { return nil }

        let unscaledPanelHeight = panelHeight / scale
        let contentAreaHeight = max(0, unscaledPanelHeight - verticalPadding * 2)
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let centeredInset = max(0, contentAreaHeight - topInset - contentHeight(visibility: visibility)) / 2
        var cursor = verticalPadding + topInset + centeredInset

        for (index, row) in rows.enumerated() {
            if index > 0 {
                cursor += spacing(between: rows[index - 1].primaryGroup, and: row.primaryGroup)
            }
            let height = row.groups.map(rowHeight(for:)).max() ?? 0
            if row.primaryGroup == targetGroup {
                return (cursor + height / 2) * scale
            }
            cursor += height
        }
        return nil
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
        case .runningThreads:
            return runningThreadsRowHeight
        case .todayModelShare, .todayModelCost:
            return todayModelRowHeight
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
        case .rateAndBar, .runningThreads, .todayModelShare, .todayModelCost,
             .quota, .radar, .crowdRadar:
            return baseSize.width - horizontalPadding * 2
        case .usageStatus:
            return 174
        case .metrics:
            return 218
        }
    }

    private static func unscaledSize(
        visibility: FloatingPanelContentVisibility,
        pagingGuidePresented: Bool = false,
        runningModelDetailsPresented: Bool = false,
        runningModelDetailsRowUnits: Int = 0
    ) -> NSSize {
        let rows = visibility.layoutRows
        guard !rows.isEmpty else { return NSSize(width: minimumControlSize.width, height: minimumControlSize.height + 2 * shellPadding) }

        let contentWidth = rows.flatMap(\.groups).map(rowWidth(for:)).max() ?? 0
        let normalWidth = max(minimumControlSize.width, horizontalPadding * 2 + contentWidth)
        let width = max(normalWidth, pagingGuidePresented ? pagingGuideWindowWidth : 0)
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let computedHeight = max(minimumControlSize.height, verticalPadding * 2 + topInset + contentHeight(visibility: visibility))
        let normalHeight = visibility == .default ? baseSize.height : computedHeight
        let height = max(
            normalHeight + 2 * shellPadding + (runningModelDetailsPresented
                ? runningModelDetailsGap + runningModelDetailsHeight(rowCount: runningModelDetailsRowUnits) + runningModelDetailsTrailingInset
                : 0),
            pagingGuidePresented ? pagingGuideHeight : 0
        )
        return NSSize(width: width, height: height)
    }

    static func cornerRadius(scale: Double) -> CGFloat {
        baseCornerRadius * clampedScale(scale)
    }
}

enum FloatingRunningModelDetailsPlacement: Equatable {
    case below
    case above
    case leading
    case trailing

    var isHorizontal: Bool { self == .leading || self == .trailing }
}

enum FloatingTokenPanelResizePolicy {
    static let screenMargin: CGFloat = 0

    static func runningModelDetailsPlacement(
        panelFrame: NSRect, surfaceSize: NSSize, expandedSize: NSSize,
        screenFrame: NSRect?, margin: CGFloat = screenMargin, attached: Bool = true
    ) -> FloatingRunningModelDetailsPlacement {
        if !attached {
            guard let screenFrame else { return .trailing }
            let extra = max(0, expandedSize.width - surfaceSize.width)
            let right = max(0, screenFrame.maxX - panelFrame.maxX - margin)
            let left = max(0, panelFrame.minX - screenFrame.minX - margin)
            return right >= extra ? .trailing : left >= extra ? .leading : right >= left ? .trailing : .leading
        }
        guard let screenFrame else { return .below }
        let extra = max(0, expandedSize.height - surfaceSize.height)
        let below = max(0, panelFrame.minY - screenFrame.minY - margin)
        let above = max(0, screenFrame.maxY - panelFrame.maxY - margin)
        if below >= extra { return .below }
        if above >= extra { return .above }
        return below >= above ? .below : .above
    }

    static func baseFrame(for panelFrame: NSRect, surfaceSize: NSSize,
                          placement: FloatingRunningModelDetailsPlacement) -> NSRect {
        NSRect(x: placement == .leading ? panelFrame.maxX - surfaceSize.width : panelFrame.minX,
               y: placement == .above ? panelFrame.minY : panelFrame.maxY - surfaceSize.height,
               width: surfaceSize.width, height: surfaceSize.height)
    }

    static func expandedFrame(baseFrame: NSRect, expandedSize: NSSize, surfaceSize: NSSize,
                              placement: FloatingRunningModelDetailsPlacement,
                              screenFrame: NSRect?, margin: CGFloat = screenMargin) -> NSRect {
        let proposedY = placement == .above ? baseFrame.minY : baseFrame.maxY - expandedSize.height
        let y: CGFloat
        if let screenFrame {
            y = min(max(proposedY, screenFrame.minY + margin), max(screenFrame.minY + margin, screenFrame.maxY - margin - expandedSize.height))
        } else { y = proposedY }
        let proposedX = placement == .leading ? baseFrame.maxX - expandedSize.width : baseFrame.minX
        let x = screenFrame.map { min(max(proposedX, $0.minX + margin), max($0.minX + margin, $0.maxX - margin - expandedSize.width)) } ?? proposedX
        return NSRect(x: x, y: y, width: expandedSize.width, height: expandedSize.height)
    }

    static func constrainedHeight(baseFrame: NSRect, expandedHeight: CGFloat, screenFrame: NSRect?, scale: CGFloat) -> CGFloat {
        guard let screenFrame else { return expandedHeight }
        let available = max(baseFrame.minY - screenFrame.minY, screenFrame.maxY - baseFrame.maxY)
        let wanted = max(0, expandedHeight - baseFrame.height)
        let minimumExtra = (FloatingTokenPanelMetrics.runningModelDetailsMinimumHeight
            + FloatingTokenPanelMetrics.runningModelDetailsGap + FloatingTokenPanelMetrics.runningModelDetailsTrailingInset) * scale
        let extra = min(wanted, max(0, screenFrame.height - baseFrame.height), max(min(wanted, minimumExtra), available))
        return baseFrame.height + extra
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
    var size: NSSize
    let cornerRadius: CGFloat
    let runningModelDetailsPresented: Bool
    let runningModelDetailsPlacement: FloatingRunningModelDetailsPlacement

    init(
        scale: FloatingTokenPanelScale,
        visibility: FloatingPanelContentVisibility,
        pagingGuidePresented: Bool = false,
        runningModelDetailsPresented: Bool = false,
        runningModelDetailsRowUnits: Int = 0,
        runningModelDetailsPlacement: FloatingRunningModelDetailsPlacement = .below
    ) {
        effectiveScale = scale.value
        self.runningModelDetailsPresented = runningModelDetailsPresented
        self.runningModelDetailsPlacement = runningModelDetailsPlacement
        size = FloatingTokenPanelMetrics.size(
            effectiveScale: scale.value,
            visibility: visibility,
            pagingGuidePresented: pagingGuidePresented,
            runningModelDetailsPresented: runningModelDetailsPresented,
            runningModelDetailsRowUnits: runningModelDetailsRowUnits
        )
        if runningModelDetailsPresented && runningModelDetailsPlacement.isHorizontal {
            let base = FloatingTokenPanelMetrics.size(effectiveScale: scale.value, visibility: visibility)
            size = NSSize(width: base.width + (FloatingTokenPanelMetrics.runningModelDetailsGap
                + FloatingTokenPanelMetrics.runningModelDetailsWidth) * scale.value,
                height: max(base.height, (FloatingTokenPanelMetrics.runningModelDetailsHeight(rowCount: runningModelDetailsRowUnits)
                    + 2 * FloatingTokenPanelMetrics.shellPadding) * scale.value))
        }
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
