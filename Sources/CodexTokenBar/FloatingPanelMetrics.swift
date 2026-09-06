import AppKit

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 258, height: 120)
    static let minimumControlSize = NSSize(width: 72, height: 34)
    static let baseCornerRadius: CGFloat = 14
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
    static let runningModelDetailsGap: CGFloat = 10
    static let runningModelDetailsWidth: CGFloat = 260
    static let runningModelDetailsTrailingInset: CGFloat = 8
    static let runningModelDetailsMinimumHeight: CGFloat = 96
    static let runningModelDetailsBaseHeight: CGFloat = 60
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
        max(
            runningModelDetailsMinimumHeight,
            runningModelDetailsBaseHeight
                + CGFloat(max(1, rowCount)) * runningModelDetailsRowHeight
        )
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
        guard !rows.isEmpty else { return minimumControlSize }

        let contentWidth = rows.flatMap(\.groups).map(rowWidth(for:)).max() ?? 0
        let normalWidth = max(minimumControlSize.width, horizontalPadding * 2 + contentWidth)
        let detailsWidth = runningModelDetailsPresented
            ? normalWidth
                + runningModelDetailsGap
                + runningModelDetailsWidth
                + runningModelDetailsTrailingInset
            : 0
        let width = max(
            max(normalWidth, detailsWidth),
            pagingGuidePresented ? pagingGuideWindowWidth : 0
        )
        let topInset = visibility.needsTopControlInset ? singleElementTopInset : 0
        let computedHeight = max(minimumControlSize.height, verticalPadding * 2 + topInset + contentHeight(visibility: visibility))
        let height = max(
            max(
                visibility == .default ? baseSize.height : computedHeight,
                runningModelDetailsPresented
                    ? runningModelDetailsHeight(rowCount: runningModelDetailsRowUnits)
                    : 0
            ),
            pagingGuidePresented ? pagingGuideHeight : 0
        )
        return NSSize(width: width, height: height)
    }

    static func cornerRadius(scale: Double) -> CGFloat {
        baseCornerRadius * clampedScale(scale)
    }
}

enum FloatingRunningModelDetailsPlacement: Equatable {
    case trailing
    case leading
}

enum FloatingTokenPanelResizePolicy {
    static let screenMargin: CGFloat = 8

    static func runningModelDetailsPlacement(
        panelFrame: NSRect,
        surfaceSize: NSSize,
        expandedSize: NSSize,
        screenFrame: NSRect?,
        margin: CGFloat = screenMargin
    ) -> FloatingRunningModelDetailsPlacement {
        let extraWidth = max(0, expandedSize.width - surfaceSize.width)
        guard extraWidth > 0, let screenFrame else {
            return .trailing
        }

        let trailingAvailable = max(0, screenFrame.maxX - panelFrame.maxX)
        let leadingAvailable = max(0, panelFrame.minX - screenFrame.minX)
        if trailingAvailable >= extraWidth + margin {
            return .trailing
        }
        if leadingAvailable >= extraWidth + margin {
            return .leading
        }
        return trailingAvailable >= leadingAvailable ? .trailing : .leading
    }

    static func baseFrame(
        for panelFrame: NSRect,
        surfaceSize: NSSize,
        placement: FloatingRunningModelDetailsPlacement
    ) -> NSRect {
        let extraWidth = max(0, panelFrame.width - surfaceSize.width)
        let originX = placement == .leading
            ? panelFrame.minX + extraWidth
            : panelFrame.minX
        return NSRect(
            x: originX,
            y: panelFrame.maxY - surfaceSize.height,
            width: surfaceSize.width,
            height: surfaceSize.height
        )
    }

    static func expandedFrame(
        baseFrame: NSRect,
        expandedSize: NSSize,
        surfaceSize: NSSize,
        placement: FloatingRunningModelDetailsPlacement,
        screenFrame: NSRect?,
        margin: CGFloat = screenMargin
    ) -> NSRect {
        let extraWidth = max(0, expandedSize.width - surfaceSize.width)
        let proposedX = placement == .leading
            ? baseFrame.minX - extraWidth
            : baseFrame.minX
        let proposedY = baseFrame.maxY - expandedSize.height
        let origin = clampedOrigin(
            NSPoint(x: proposedX, y: proposedY),
            size: expandedSize,
            screenFrame: screenFrame,
            margin: margin
        )
        return NSRect(origin: origin, size: expandedSize)
    }

    private static func clampedOrigin(
        _ proposed: NSPoint,
        size: NSSize,
        screenFrame: NSRect?,
        margin: CGFloat
    ) -> NSPoint {
        guard let screenFrame else { return proposed }
        let minimumX = screenFrame.minX + margin
        let maximumX = max(minimumX, screenFrame.maxX - size.width - margin)
        let minimumY = screenFrame.minY + margin
        let maximumY = max(minimumY, screenFrame.maxY - size.height - margin)
        return NSPoint(
            x: min(max(proposed.x, minimumX), maximumX),
            y: min(max(proposed.y, minimumY), maximumY)
        )
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
    let runningModelDetailsPresented: Bool
    let runningModelDetailsPlacement: FloatingRunningModelDetailsPlacement

    init(
        scale: FloatingTokenPanelScale,
        visibility: FloatingPanelContentVisibility,
        pagingGuidePresented: Bool = false,
        runningModelDetailsPresented: Bool = false,
        runningModelDetailsRowUnits: Int = 0,
        runningModelDetailsPlacement: FloatingRunningModelDetailsPlacement = .trailing
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
