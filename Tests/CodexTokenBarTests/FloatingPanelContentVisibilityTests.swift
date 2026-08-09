import XCTest
@testable import CodexTokenBar

final class FloatingPanelContentVisibilityTests: XCTestCase {
    func testDefaultVisibilityShowsAllFloatingPanelGroups() {
        let visibility = FloatingPanelContentVisibility.default

        XCTAssertEqual(visibility.visibleGroups, [.rateAndBar, .usageStatus, .metrics, .runningThreads, .todayModelShare, .todayModelCost, .radar, .crowdRadar, .quota])
        XCTAssertEqual(FloatingPanelContentVisibility.defaultOrder, [.rateAndBar, .usageStatus, .metrics, .runningThreads, .todayModelShare, .todayModelCost, .radar, .crowdRadar, .quota])
        XCTAssertEqual(FloatingPanelContentVisibility.defaultOrderRaw, "rateAndBar,usageStatus,metrics,runningThreads,todayModelShare,todayModelCost,radar,crowdRadar,quota")
        XCTAssertTrue(visibility.shows(.rateAndBar))
        XCTAssertTrue(visibility.shows(.usageStatus))
        XCTAssertTrue(visibility.shows(.metrics))
        XCTAssertTrue(visibility.shows(.runningThreads))
        XCTAssertTrue(visibility.shows(.todayModelShare))
        XCTAssertTrue(visibility.shows(.todayModelCost))
        XCTAssertTrue(visibility.shows(.quota))
        XCTAssertTrue(visibility.shows(.radar))
        XCTAssertTrue(visibility.shows(.crowdRadar))
        XCTAssertTrue(visibility.showPageNavigationArrows)
    }

    func testPageNavigationArrowsCanBeHiddenWithoutChangingPagePairs() {
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showTodayModelShare: true,
            showTodayModelCost: true,
            showQuota: true,
            showRadar: true,
            showPageNavigationArrows: false
        )

        XCTAssertFalse(visibility.showPageNavigationArrows)
        XCTAssertEqual(visibility.pagePairs, FloatingPanelContentVisibility.defaultPagePairs)
        XCTAssertTrue(visibility.layoutRows.contains(where: \.isPaged))
    }

    func testAdaptiveSizeShrinksWhenOnlyUsageStatusIsVisible() {
        let fullSize = FloatingTokenPanelMetrics.size(scale: 1, visibility: .default)
        let statusOnlySize = FloatingTokenPanelMetrics.size(
            scale: 1,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: true,
                showMetrics: false,
                showQuota: false,
                showRadar: false
            )
        )

        XCTAssertLessThan(statusOnlySize.width, fullSize.width)
        XCTAssertLessThan(statusOnlySize.height, fullSize.height)
    }

    func testUsageStatusEmbedsIntoRateRowWhenRateIsVisible() {
        let height = FloatingTokenPanelMetrics.contentHeight(visibility: .default)
        let expectedHeight = FloatingTokenPanelMetrics.rateRowHeight
            + FloatingTokenPanelMetrics.metricRowHeight
            + FloatingTokenPanelMetrics.todayModelRowHeight
            + FloatingTokenPanelMetrics.quotaRowHeight
            + FloatingTokenPanelMetrics.radarRowHeight
            + FloatingTokenPanelMetrics.crowdRadarRowHeight
            + FloatingTokenPanelMetrics.rowSpacing * 4
            + FloatingTokenPanelMetrics.radarCrowdRowSpacing

        XCTAssertEqual(height, expectedHeight, accuracy: 0.001)
    }

    func testDefaultFloatingPanelUsesTighterVerticalRhythm() {
        XCTAssertEqual(FloatingTokenPanelMetrics.baseSize.height, 138, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.verticalPadding, 6, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.rowSpacing, 2, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.rateRowHeight, 28, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.usageStatusRowHeight, 20, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.metricRowHeight, 13, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.runningThreadsRowHeight, 14, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.todayModelRowHeight, 17, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.quotaRowHeight, 15.5, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.radarRowHeight, 24, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.crowdRadarRowHeight, 20, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.contentHeight(visibility: .default), 125.5, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: .default).height, 138, accuracy: 0.001)
    }

    func testDefaultMetricsEmbedMainAndSubagentCountsOnTheRight() {
        let visibility = FloatingPanelContentVisibility.default

        XCTAssertTrue(visibility.embedsRunningThreadsInMetricsRow)
        XCTAssertEqual(
            visibility.layoutGroups,
            [.rateAndBar, .metrics, .todayModelShare, .todayModelCost, .radar, .crowdRadar, .quota]
        )
        XCTAssertEqual(
            visibility.layoutRows.map(\.groups),
            [[.rateAndBar], [.metrics], [.todayModelShare, .todayModelCost], [.radar], [.crowdRadar], [.quota]]
        )
    }

    func testPagePairsSanitizeConflictsAndCanChangeDefaultPage() {
        let decoded = FloatingPanelContentVisibility.pagePairs(
            from: "todayModelShare|todayModelCost,radar|crowdRadar,radar|quota,rateAndBar|metrics"
        )

        XCTAssertEqual(decoded, [
            FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
            FloatingPanelPagePair(first: .radar, second: .crowdRadar),
        ])
        XCTAssertEqual(
            FloatingPanelContentVisibility.swappingDefaultPage(in: decoded, for: .todayModelCost),
            [
                FloatingPanelPagePair(first: .todayModelCost, second: .todayModelShare),
                FloatingPanelPagePair(first: .radar, second: .crowdRadar),
            ]
        )
    }

    func testReplacingPagePartnerRemovesPreviousPairOnBothSides() {
        let pairs = [
            FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
            FloatingPanelPagePair(first: .radar, second: .crowdRadar),
        ]

        XCTAssertEqual(
            FloatingPanelContentVisibility.replacingPagePartner(
                in: pairs,
                for: .todayModelShare,
                with: .radar
            ),
            [FloatingPanelPagePair(first: .todayModelShare, second: .radar)]
        )
    }

    func testRunningThreadsStayStandaloneWhenSeparatedFromMetrics() {
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: true,
            showRunningThreads: true,
            showQuota: false,
            showRadar: true,
            groupOrder: [.metrics, .radar, .runningThreads]
        )

        XCTAssertFalse(visibility.embedsRunningThreadsInMetricsRow)
        XCTAssertEqual(visibility.layoutGroups, [.metrics, .radar, .runningThreads])
    }

    func testRadarCrowdPairTightensOnlyItsUpperGap() {
        XCTAssertEqual(
            FloatingTokenPanelMetrics.spacing(between: .radar, and: .crowdRadar),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloatingTokenPanelMetrics.spacing(between: .crowdRadar, and: .quota),
            FloatingTokenPanelMetrics.rowSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloatingTokenPanelMetrics.spacing(between: .metrics, and: .radar),
            FloatingTokenPanelMetrics.rowSpacing,
            accuracy: 0.001
        )
    }

    func testUsageStatusEmbedsOnlyWhenAdjacentToRateRow() {
        let adjacentAfterRate = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.rateAndBar, .usageStatus, .metrics, .quota, .radar]
        )
        let adjacentBeforeRate = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.usageStatus, .rateAndBar, .metrics, .quota, .radar]
        )
        let separatedAfterRate = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.rateAndBar, .metrics, .usageStatus, .quota, .radar]
        )
        let separatedBeforeRate = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.usageStatus, .metrics, .rateAndBar, .quota, .radar]
        )

        XCTAssertTrue(adjacentAfterRate.embedsUsageStatusInRateRow)
        XCTAssertTrue(adjacentBeforeRate.embedsUsageStatusInRateRow)
        XCTAssertEqual(adjacentAfterRate.layoutGroups, [.rateAndBar, .metrics, .quota, .radar])
        XCTAssertEqual(adjacentBeforeRate.layoutGroups, [.rateAndBar, .metrics, .quota, .radar])

        XCTAssertFalse(separatedAfterRate.embedsUsageStatusInRateRow)
        XCTAssertFalse(separatedBeforeRate.embedsUsageStatusInRateRow)
        XCTAssertEqual(separatedAfterRate.layoutGroups, [.rateAndBar, .metrics, .usageStatus, .quota, .radar])
        XCTAssertEqual(separatedBeforeRate.layoutGroups, [.usageStatus, .metrics, .rateAndBar, .quota, .radar])
    }

    func testUsageStatusUsesStandaloneRowOnlyWhenRateIsHidden() {
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )

        XCTAssertEqual(
            FloatingTokenPanelMetrics.contentHeight(visibility: visibility),
            FloatingTokenPanelMetrics.usageStatusRowHeight,
            accuracy: 0.001
        )
    }

    func testFloatingPanelLayoutGroupsFollowStoredOrder() {
        let decoded = FloatingPanelContentVisibility.order(from: "radar,metrics,rateAndBar,unknown,radar")
        XCTAssertEqual(decoded, [.radar, .crowdRadar, .metrics, .runningThreads, .todayModelShare, .todayModelCost, .rateAndBar, .usageStatus, .quota])
        XCTAssertEqual(FloatingPanelContentVisibility.encodedOrder(decoded), "radar,crowdRadar,metrics,runningThreads,todayModelShare,todayModelCost,rateAndBar,usageStatus,quota")

        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.radar, .metrics, .rateAndBar, .usageStatus, .quota]
        )

        XCTAssertEqual(visibility.visibleGroups, [.radar, .metrics, .rateAndBar, .usageStatus, .quota])
        XCTAssertEqual(visibility.layoutGroups, [.radar, .metrics, .rateAndBar, .quota])
    }

    func testFloatingPanelContentOrderKeepsStandaloneUsageStatusInOrder() {
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: false,
            showRadar: false,
            groupOrder: [.metrics, .usageStatus, .rateAndBar, .quota, .radar]
        )

        XCTAssertEqual(visibility.layoutGroups, [.metrics, .usageStatus])
    }

    func testFloatingPanelPresentationRowsFollowVisibilityLayoutOrder() {
        let snapshot = makeTokenDisplaySnapshot()
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.radar, .metrics, .rateAndBar, .usageStatus, .quota]
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertEqual(model.rows.map(\.group), [.radar, .metrics, .rateAndBar, .quota])
        XCTAssertEqual(model.rateBarUsageStatus, snapshot.compactUsageStatus)
        XCTAssertNil(model.standaloneUsageStatus)
        XCTAssertTrue(model.needsTopSafetyInset)
    }

    func testFloatingPanelPresentationUsesStandaloneUsageStatusWhenSeparatedFromRateRow() {
        let snapshot = makeTokenDisplaySnapshot()
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: false,
            showRadar: false,
            groupOrder: [.rateAndBar, .metrics, .usageStatus, .quota, .radar]
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertEqual(model.rows.map(\.group), [.rateAndBar, .metrics, .usageStatus])
        XCTAssertNil(model.rateBarUsageStatus)
        XCTAssertEqual(model.standaloneUsageStatus, snapshot.standaloneUsageStatus)
    }

    func testFloatingPanelPresentationOmitsUsageStatusWhenHidden() {
        let snapshot = makeTokenDisplaySnapshot(quota: .empty)
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: false,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertEqual(model.rows.map(\.group), [.rateAndBar])
        XCTAssertNil(model.rateBarUsageStatus)
        XCTAssertNil(model.standaloneUsageStatus)
        XCTAssertFalse(model.accessibilityParts.contains("读取中"))
    }

    func testFloatingPanelRunningThreadsRowUsesSharedCountsAndAccessibility() {
        let running = RunningThreadSummary(
            main: 2,
            subagents: 3,
            updatedAt: Date(timeIntervalSince1970: 100),
            freshness: .fresh
        )
        let snapshot = makeTokenDisplaySnapshot(runningThreads: running)
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: false,
            showRunningThreads: true,
            showQuota: false,
            showRadar: false
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertEqual(model.rows.map(\.group), [.runningThreads])
        XCTAssertTrue(model.accessibilityValue.contains("当前运行 5 个线程"))
        XCTAssertTrue(model.accessibilityValue.contains("子 Agent 3 个"))
    }

    func testFloatingPanelAccessibilityUsesPendingLabelsForMetadataOnlyMetrics() {
        let snapshot = makeTokenDisplaySnapshot(usagePrecision: .metadataOnly)
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: true,
            showQuota: false,
            showRadar: false
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertTrue(model.accessibilityParts.contains("累计 待读取 token"))
        XCTAssertTrue(model.accessibilityParts.contains("今天 待读取 token"))
        XCTAssertTrue(model.accessibilityParts.contains("今天 待读取 次请求"))
        XCTAssertFalse(model.accessibilityValue.contains("123456"))
        XCTAssertFalse(model.accessibilityValue.contains("7890"))
    }

    func testPendingMetricLabelsStayCenteredInsideTheirEqualWidthSlots() {
        XCTAssertEqual(FloatingTokenPanelMetrics.metricTotalOffset(hasPreciseTokenUsage: false), 0)
        XCTAssertEqual(FloatingTokenPanelMetrics.metricTodayOffset(hasPreciseTokenUsage: false), 0)
        XCTAssertEqual(
            FloatingTokenPanelMetrics.metricRequestsOffset(requestCount: 0, hasPreciseTokenUsage: false),
            0
        )

        let rowWidth = FloatingTokenPanelMetrics.rowWidth(for: .metrics)
        let slotWidth = (rowWidth - 2 * 6) / 3
        let labelWidth = ("次" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.4, weight: .medium),
        ]).width
        let valueWidth = ("待读取" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.4, weight: .semibold),
        ]).width

        XCTAssertLessThanOrEqual(labelWidth + 3 + valueWidth, slotWidth)
    }

    func testFloatingPanelAccessibilityUsesPreciseMetricLabelsWhenAvailable() {
        let snapshot = makeTokenDisplaySnapshot()
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: true,
            showQuota: false,
            showRadar: false
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertTrue(model.accessibilityParts.contains("累计 \(snapshot.consumedTokensText) token"))
        XCTAssertTrue(model.accessibilityParts.contains("今天 \(snapshot.todayTokensText) token"))
        XCTAssertTrue(model.accessibilityParts.contains("今天 \(snapshot.todayRequestsText) 次请求"))
    }

    func testFloatingPanelMarksRetainedPreciseUsageAsStaleWithoutHidingMetrics() {
        let snapshot = makeTokenDisplaySnapshot(
            usageReadStatus: "手动目录 · 用量已陈旧 · 当前仅元数据，保留上次可信 token"
        )
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: false,
            showRadar: false
        )

        let model = FloatingPanelPresentationModel(snapshot: snapshot, visibility: visibility)

        XCTAssertEqual(model.standaloneUsageStatus, "用量已陈旧")
        XCTAssertTrue(model.accessibilityParts.contains("累计 \(snapshot.consumedTokensText) token"))
        XCTAssertTrue(model.accessibilityParts.contains("用量已陈旧"))
        XCTAssertFalse(model.accessibilityValue.contains("待读取"))
    }

    func testFloatingPanelContentOrderReordersAroundDropTargetWithoutDuplicates() {
        let order: [FloatingPanelContentGroup] = [.rateAndBar, .usageStatus, .metrics, .quota, .radar]

        XCTAssertEqual(
            FloatingPanelContentVisibility.reorderedOrder(
                order,
                moving: .rateAndBar,
                relativeTo: .metrics,
                placement: .after
            ),
            [.usageStatus, .metrics, .rateAndBar, .runningThreads, .todayModelShare, .todayModelCost, .quota, .radar, .crowdRadar]
        )

        XCTAssertEqual(
            FloatingPanelContentVisibility.reorderedOrder(
                order,
                moving: .radar,
                relativeTo: .usageStatus,
                placement: .before
            ),
            [.rateAndBar, .radar, .usageStatus, .metrics, .runningThreads, .todayModelShare, .todayModelCost, .quota, .crowdRadar]
        )
    }

    func testStructureEditorMovesWholePagedAndInlineRows() {
        let visibility = FloatingPanelContentVisibility.default
        let rows = visibility.layoutRows
        let metrics = rows.first { $0.primaryGroup == .metrics }!
        let model = rows.first { $0.primaryGroup == .todayModelShare }!

        XCTAssertEqual(visibility.editorGroups(for: metrics), [.metrics, .runningThreads])
        XCTAssertEqual(visibility.editorGroups(for: model), [.todayModelShare, .todayModelCost])
        XCTAssertEqual(
            FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: visibility.editorGroups(for: model),
                relativeTo: visibility.editorGroups(for: metrics),
                placement: .before
            ),
            [.rateAndBar, .usageStatus, .todayModelShare, .todayModelCost, .metrics, .runningThreads, .radar, .crowdRadar, .quota]
        )
    }

    func testStructureEditorMergeSplitAndGroupedVisibilityPreserveV01Pairs() {
        var visibility = FloatingPanelContentVisibility.default
        visibility.pagePairs = FloatingPanelContentVisibility.mergingPage(
            in: visibility.pagePairs,
            group: .radar,
            into: .crowdRadar
        )
        XCTAssertEqual(visibility.pagePairs, [
            FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
            FloatingPanelPagePair(first: .crowdRadar, second: .radar),
        ])

        visibility.setVisible(false, for: [.crowdRadar, .radar])
        XCTAssertFalse(visibility.shows(.crowdRadar))
        XCTAssertFalse(visibility.shows(.radar))
        XCTAssertEqual(visibility.pagePairs, [
            FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
            FloatingPanelPagePair(first: .crowdRadar, second: .radar),
        ])

        visibility.pagePairs = FloatingPanelContentVisibility.splittingPage(
            in: visibility.pagePairs,
            group: .radar
        )
        XCTAssertEqual(visibility.pagePairs, [
            FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
        ])
    }

    func testAdaptiveSizeKeepsControlsReachableWhenAllGroupsAreHidden() {
        let hiddenSize = FloatingTokenPanelMetrics.size(
            scale: 1,
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: false,
                showRadar: false
            )
        )

        XCTAssertGreaterThanOrEqual(hiddenSize.width, FloatingTokenPanelMetrics.minimumControlSize.width)
        XCTAssertGreaterThanOrEqual(hiddenSize.height, FloatingTokenPanelMetrics.minimumControlSize.height)
        XCTAssertLessThan(hiddenSize.width, FloatingTokenPanelMetrics.size(scale: 1, visibility: .default).width)
    }

    func testFloatingPanelReadableTextPaletteCompressesGrayBandIntoBlackOrWhiteFamilies() {
        let lightAppearance = FloatingPanelAppearance(
            startHex: "#FFFFFF",
            endHex: "#E6F4FF",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let darkAppearance = FloatingPanelAppearance(
            startHex: "#07111F",
            endHex: "#111827",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let grayBandAppearance = FloatingPanelAppearance(
            startHex: "#999999",
            endHex: "#999999",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let outerBandAppearance = FloatingPanelAppearance(
            startHex: "#777777",
            endHex: "#777777",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )

        let lightPalette = lightAppearance.readableTextPalette
        let darkPalette = darkAppearance.readableTextPalette
        let grayBandPalette = grayBandAppearance.readableTextPalette
        let outerBandPalette = outerBandAppearance.readableTextPalette

        XCTAssertLessThan(lightPalette.primaryWhite, 0.18)
        XCTAssertGreaterThan(lightPalette.secondaryWhite, lightPalette.primaryWhite)
        XCTAssertLessThan(grayBandPalette.primaryWhite, 0.24)
        XCTAssertGreaterThan(grayBandPalette.secondaryWhite, grayBandPalette.primaryWhite)
        XCTAssertGreaterThan(outerBandPalette.primaryWhite, 0.80)
        XCTAssertLessThan(outerBandPalette.secondaryWhite, outerBandPalette.primaryWhite)
        XCTAssertGreaterThan(darkPalette.primaryWhite, 0.82)
        XCTAssertLessThan(darkPalette.secondaryWhite, darkPalette.primaryWhite)
        XCTAssertGreaterThan(outerBandPalette.primaryWhite - grayBandPalette.primaryWhite, 0.56)
    }

    func testFloatingPanelReadableTextPaletteJumpsBetweenBlackAndWhiteFamiliesWithoutMiddleGray() {
        let justBeforeSwitch = FloatingPanelReadableTextPalette(backgroundLuminance: 0.546)
        let justAfterSwitch = FloatingPanelReadableTextPalette(backgroundLuminance: 0.544)
        let lightestBackground = FloatingPanelReadableTextPalette(backgroundLuminance: 1)
        let darkestBackground = FloatingPanelReadableTextPalette(backgroundLuminance: 0)

        XCTAssertLessThanOrEqual(justBeforeSwitch.primaryWhite, 0.15)
        XCTAssertLessThan(justBeforeSwitch.secondaryWhite, 0.24)
        XCTAssertLessThan(justBeforeSwitch.mutedWhite, 0.30)
        XCTAssertGreaterThan(justAfterSwitch.primaryWhite, 0.88)
        XCTAssertGreaterThan(justAfterSwitch.secondaryWhite, 0.78)
        XCTAssertGreaterThan(justAfterSwitch.mutedWhite, 0.72)
        XCTAssertGreaterThan(justAfterSwitch.primaryWhite - justBeforeSwitch.primaryWhite, 0.70)
        XCTAssertFalse((0.35...0.65).contains(justBeforeSwitch.primaryWhite))
        XCTAssertFalse((0.35...0.65).contains(justAfterSwitch.primaryWhite))
        XCTAssertEqual(lightestBackground.primaryWhite, 0, accuracy: 0.001)
        XCTAssertEqual(lightestBackground.secondaryWhite, 0.08, accuracy: 0.001)
        XCTAssertEqual(lightestBackground.mutedWhite, 0.12, accuracy: 0.001)
        XCTAssertEqual(darkestBackground.primaryWhite, 1, accuracy: 0.001)
        XCTAssertEqual(darkestBackground.secondaryWhite, 0.92, accuracy: 0.001)
        XCTAssertEqual(darkestBackground.mutedWhite, 0.86, accuracy: 0.001)
    }

    func testFloatingPanelReadableTextPaletteAdaptsFromBackgroundSamples() {
        let lightPalette = FloatingPanelReadableTextPalette(backgroundSamples: [
            FloatingPanelBackgroundSample(red: 1, green: 1, blue: 1),
            FloatingPanelBackgroundSample(red: 0.90, green: 0.96, blue: 1.0),
        ])
        let saturatedPalette = FloatingPanelReadableTextPalette(backgroundSamples: [
            FloatingPanelBackgroundSample(red: 0.03, green: 0.26, blue: 0.72),
            FloatingPanelBackgroundSample(red: 0.08, green: 0.36, blue: 0.82),
        ])
        let grayBandPalette = FloatingPanelReadableTextPalette(backgroundSamples: [
            FloatingPanelBackgroundSample(red: 0.60, green: 0.60, blue: 0.60),
            FloatingPanelBackgroundSample(red: 0.55, green: 0.55, blue: 0.55),
        ])

        XCTAssertLessThan(lightPalette.primaryWhite, 0.18)
        XCTAssertGreaterThan(saturatedPalette.primaryWhite, 0.86)
        XCTAssertGreaterThan(grayBandPalette.primaryWhite, lightPalette.primaryWhite)
        XCTAssertLessThan(grayBandPalette.primaryWhite, saturatedPalette.primaryWhite)
        XCTAssertLessThan(grayBandPalette.primaryWhite, 0.24)
    }

    func testFloatingPanelSamplesVisibleGlassCompositingForPaleRadarArea() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#2459FF",
            endHex: "#FFFFFF",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let paletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: .default),
            scale: 1,
            opacity: 0.88,
            visibility: .default
        )

        let radarPalette = try XCTUnwrap(paletteSet.rowPalettes[.radar])

        XCTAssertLessThan(radarPalette.primaryWhite, 0.24)
        XCTAssertLessThan(radarPalette.secondaryWhite, 0.40)
    }

    func testFloatingPanelSamplesRadarActionAndModelRegionsSeparately() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#FFFFFF",
            endHex: "#07111F",
            directionRaw: FloatingPanelGradientDirection.leadingToTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let paletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: .default),
            scale: 1,
            opacity: 0.88,
            visibility: .default
        )

        let actionPalette = try XCTUnwrap(paletteSet.radarActionPalette)
        let modelPalette = try XCTUnwrap(paletteSet.radarModelPalette)

        XCTAssertLessThan(actionPalette.primaryWhite, 0.24)
        XCTAssertGreaterThan(modelPalette.primaryWhite, 0.80)
        XCTAssertGreaterThan(modelPalette.primaryWhite - actionPalette.primaryWhite, 0.56)
    }

    func testFloatingPanelPullsBackSingleNearBoundaryWhiteRegionForUnifiedTone() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#FAF9FF",
            endHex: "#0058DF",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: true,
            showRadar: true,
            groupOrder: [.usageStatus, .rateAndBar, .metrics, .radar, .quota]
        )
        let paletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1.14, visibility: visibility),
            scale: 1.14,
            opacity: 0.98,
            visibility: visibility
        )

        let requestsPalette = try XCTUnwrap(paletteSet.metricPalettes[.requests])
        let radarModelPalette = try XCTUnwrap(paletteSet.radarModelPalette)

        XCTAssertLessThan(requestsPalette.primaryWhite, 0.24)
        XCTAssertLessThan(radarModelPalette.primaryWhite, 0.24)
        XCTAssertLessThan(abs(radarModelPalette.primaryWhite - requestsPalette.primaryWhite), 0.08)
    }

    func testFloatingPanelSamplesMetricRegionsSeparately() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#FFFFFF",
            endHex: "#07111F",
            directionRaw: FloatingPanelGradientDirection.leadingToTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let paletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: .default),
            scale: 1,
            opacity: 0.88,
            visibility: .default
        )

        let totalPalette = try XCTUnwrap(paletteSet.metricPalettes[.total])
        let todayPalette = try XCTUnwrap(paletteSet.metricPalettes[.today])
        let requestsPalette = try XCTUnwrap(paletteSet.metricPalettes[.requests])

        XCTAssertLessThan(totalPalette.primaryWhite, 0.24)
        XCTAssertGreaterThan(requestsPalette.primaryWhite, 0.80)
        XCTAssertGreaterThan(todayPalette.primaryWhite, totalPalette.primaryWhite)
        XCTAssertGreaterThan(requestsPalette.primaryWhite - totalPalette.primaryWhite, 0.56)
    }

    func testFloatingPanelSamplesBothUsageStatusStylesSeparately() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#FFFFFF",
            endHex: "#07111F",
            directionRaw: FloatingPanelGradientDirection.leadingToTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let embeddedVisibility = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let standaloneVisibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let embeddedPaletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: embeddedVisibility),
            scale: 1,
            opacity: 0.88,
            visibility: embeddedVisibility
        )
        let standalonePaletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: standaloneVisibility),
            scale: 1,
            opacity: 0.88,
            visibility: standaloneVisibility
        )

        let ratePalette = try XCTUnwrap(embeddedPaletteSet.rowPalettes[.rateAndBar])
        let embeddedStatusPalette = try XCTUnwrap(embeddedPaletteSet.embeddedUsageStatusPalette)
        let standaloneStatusPalette = try XCTUnwrap(standalonePaletteSet.standaloneUsageStatusPalette)

        XCTAssertGreaterThan(embeddedStatusPalette.primaryWhite, ratePalette.primaryWhite)
        XCTAssertGreaterThan(embeddedStatusPalette.primaryWhite - ratePalette.primaryWhite, 0.05)
        XCTAssertGreaterThan(standaloneStatusPalette.primaryWhite, 0.68)
        XCTAssertFalse((0.35...0.65).contains(standaloneStatusPalette.primaryWhite))
    }

    func testFloatingPanelSamplesDifferentRowsFromTheActualGradientArea() throws {
        let appearance = FloatingPanelAppearance(
            startHex: "#07111F",
            endHex: "#FFFFFF",
            directionRaw: FloatingPanelGradientDirection.topToBottom.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let paletteSet = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(scale: 1, visibility: .default),
            scale: 1,
            opacity: 0.88,
            visibility: .default
        )

        let ratePalette = try XCTUnwrap(paletteSet.rowPalettes[.rateAndBar])
        let radarPalette = try XCTUnwrap(paletteSet.rowPalettes[.radar])

        XCTAssertGreaterThan(ratePalette.primaryWhite, 0.82)
        XCTAssertLessThan(radarPalette.primaryWhite, 0.32)
        XCTAssertGreaterThan(ratePalette.primaryWhite - radarPalette.primaryWhite, 0.45)
    }

    func testFloatingPanelTextPalettesReuseCachedSamplingForUnchangedLayout() {
        FloatingPanelAppearance.resetTextPaletteCacheForTesting()
        let appearance = FloatingPanelAppearance(
            startHex: "#FAF9FF",
            endHex: "#00C2EF",
            directionRaw: FloatingPanelGradientDirection.topLeadingToBottomTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let size = FloatingTokenPanelMetrics.size(scale: 1.14, visibility: .default)

        _ = appearance.textPalettes(
            panelSize: size,
            scale: 1.14,
            opacity: 0.98,
            visibility: .default
        )
        XCTAssertEqual(FloatingPanelAppearance.textPaletteCacheMissCountForTesting(), 1)

        _ = appearance.textPalettes(
            panelSize: size,
            scale: 1.14,
            opacity: 0.98,
            visibility: .default
        )
        XCTAssertEqual(FloatingPanelAppearance.textPaletteCacheMissCountForTesting(), 1)

        _ = appearance.textPalettes(
            panelSize: size,
            scale: 1.14,
            opacity: 0.88,
            visibility: .default
        )
        XCTAssertEqual(FloatingPanelAppearance.textPaletteCacheMissCountForTesting(), 2)
    }

    func testTopSafetyInsetOnlyAppearsWhenFirstRenderedGroupNeedsControlClearance() {
        let rateOnlyWithoutUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: true,
            showUsageStatus: false,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let statusOnlyWithUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )
        let radarOnlyWithoutUsageStatus = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: false,
            showMetrics: false,
            showQuota: false,
            showRadar: true
        )
        let metricsFirstWithUsageStatusLater = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: true,
            showQuota: false,
            showRadar: false,
            groupOrder: [.metrics, .usageStatus, .rateAndBar, .quota, .radar]
        )
        let rateOnlyHeight = FloatingTokenPanelMetrics.verticalPadding * 2
            + FloatingTokenPanelMetrics.rateRowHeight
        let statusOnlyHeight = max(
            FloatingTokenPanelMetrics.minimumControlSize.height,
            FloatingTokenPanelMetrics.verticalPadding * 2 + FloatingTokenPanelMetrics.usageStatusRowHeight
        )
        let radarOnlyHeight = FloatingTokenPanelMetrics.verticalPadding * 2
            + FloatingTokenPanelMetrics.singleElementTopInset
            + FloatingTokenPanelMetrics.radarRowHeight

        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: rateOnlyWithoutUsageStatus).height, rateOnlyHeight, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: statusOnlyWithUsageStatus).height, statusOnlyHeight, accuracy: 0.001)
        XCTAssertEqual(FloatingTokenPanelMetrics.size(scale: 1, visibility: radarOnlyWithoutUsageStatus).height, radarOnlyHeight, accuracy: 0.001)
        XCTAssertFalse(rateOnlyWithoutUsageStatus.needsTopControlInset)
        XCTAssertFalse(statusOnlyWithUsageStatus.needsTopControlInset)
        XCTAssertTrue(radarOnlyWithoutUsageStatus.needsTopControlInset)
        XCTAssertTrue(metricsFirstWithUsageStatusLater.needsTopControlInset)
    }

    func testFloatingPanelSettingsExposeFiveContentToggles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelAppearanceSettingsView.swift")
        let visibilityModel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelContentVisibility.swift")
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let liveRateView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let appSettingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/AppSettingsView.swift")
        let structureEditor = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelStructureEditor.swift")
        let quotaViews = projectRoot.appendingPathComponent("Sources/CodexTokenBar/AccountQuotaViews.swift")
        let settingsSource = try String(contentsOf: settingsView, encoding: .utf8)
        let visibilitySource = try String(contentsOf: visibilityModel, encoding: .utf8)
        let dashboardSource = try String(contentsOf: dashboardView, encoding: .utf8)
        let liveRateSource = try String(contentsOf: liveRateView, encoding: .utf8)
        let appSettingsSource = try String(contentsOf: appSettingsView, encoding: .utf8)
        let structureEditorSource = try String(contentsOf: structureEditor, encoding: .utf8)
        let quotaViewsSource = try String(contentsOf: quotaViews, encoding: .utf8)
        let liveRateControls = try XCTUnwrap(sourceBlock(
            named: "LiveRateControls",
            in: liveRateSource,
            endingBefore: "private struct LiveRateResetButton"
        ))

        XCTAssertFalse(settingsSource.contains("FloatingPanelContentSettings()"))
        XCTAssertTrue(settingsSource.contains("struct FloatingPanelContentSettingsButton"))
        XCTAssertTrue(settingsSource.contains("struct FloatingPanelContentSettingsMenu"))
        XCTAssertTrue(settingsSource.contains("FloatingPanelContentSettingsButtonBoundsKey"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.orderKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.rateAndBarKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.usageStatusKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.metricsKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.todayModelShareKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.todayModelCostKey)"))
        XCTAssertTrue(appSettingsSource.contains("@Binding var pagePairsRaw: String"))
        XCTAssertTrue(dashboardSource.contains("@AppStorage(FloatingPanelContentVisibility.pagePairsKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.quotaKey)"))
        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelContentVisibility.radarKey)"))
        XCTAssertTrue(settingsSource.contains("Image(systemName: \"line.3.horizontal\")"))
        XCTAssertTrue(settingsSource.contains("struct FloatingPanelContentDragHandle"))
        XCTAssertTrue(settingsSource.contains("struct FloatingPanelContentDropDelegate"))
        XCTAssertTrue(settingsSource.contains("settingsSubtitle"))
        XCTAssertTrue(visibilitySource.contains("与速率相邻会吸附"))
        XCTAssertTrue(settingsSource.contains(".onDrag {"))
        XCTAssertTrue(settingsSource.contains(".onDrop(of:"))
        XCTAssertFalse(settingsSource.contains(".draggable(group.rawValue)"))
        XCTAssertFalse(settingsSource.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(dashboardSource.contains("@AppStorage(FloatingPanelContentVisibility.rateAndBarKey)"))
        XCTAssertTrue(dashboardSource.contains("@AppStorage(FloatingPanelContentVisibility.orderKey)"))
        XCTAssertTrue(dashboardSource.contains(".overlayPreferenceValue(FloatingPanelContentSettingsButtonBoundsKey.self)"))
        XCTAssertTrue(dashboardSource.contains("FloatingPanelContentSettingsMenu("))
        XCTAssertTrue(dashboardSource.contains("floatingPanelVisibility: floatingPanelContentVisibility"))
        XCTAssertFalse(liveRateControls.contains("title: \"精确 token 统计\""))
        XCTAssertFalse(liveRateControls.contains("FloatingPanelContentSettingsButton("))
        XCTAssertTrue(liveRateControls.contains("Label(\"总体设置\", systemImage: \"gearshape\")"))
        XCTAssertTrue(appSettingsSource.contains("settingsToggle(\"精确 token 统计\""))
        XCTAssertTrue(appSettingsSource.contains("FloatingPanelStructureEditor("))
        XCTAssertFalse(appSettingsSource.contains("private var floatingPanelPreview"))
        XCTAssertTrue(appSettingsSource.contains("textTone: floatingPanelTextTone"))
        XCTAssertTrue(appSettingsSource.contains("quotaColorMode: quotaColorMode"))
        XCTAssertTrue(structureEditorSource.contains("结构编辑器"))
        XCTAssertTrue(structureEditorSource.contains("实时预览"))
        XCTAssertTrue(structureEditorSource.contains("appearance.textPalettes("))
        XCTAssertTrue(structureEditorSource.contains(".environment(\\.tokenDisplayQuotaColorStyle, quotaColorStyle)"))
        XCTAssertTrue(structureEditorSource.contains("已隐藏"))
        XCTAssertTrue(structureEditorSource.contains("恢复默认布局"))
        XCTAssertTrue(structureEditorSource.contains(".onDrag"))
        XCTAssertTrue(structureEditorSource.contains(".onDrop"))
        XCTAssertFalse(liveRateControls.contains("AccountQuotaRefreshCadencePicker"))
        XCTAssertFalse(settingsSource.contains("AccountQuotaRefreshCadencePicker"))
        XCTAssertTrue(quotaViewsSource.contains("AccountQuotaRefreshCadencePicker()"))
    }

    func testAppSettingsUsesSharedCategorizedNavigationAndMaintenanceActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSettingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/AppSettingsView.swift")
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let appSettingsSource = try String(contentsOf: appSettingsView, encoding: .utf8)
        let dashboardSource = try String(contentsOf: dashboardView, encoding: .utf8)

        for category in ["常规", "会话增强", "Codex 实例", "自动续跑", "显示面", "状态栏", "监控与额度", "悬浮窗", "提醒与更新", "数据与维护"] {
            XCTAssertTrue(appSettingsSource.contains("return \"\(category)\""), category)
        }
        XCTAssertFalse(AppSettingsCategory.allCases.contains(.content))
        XCTAssertEqual(AppSettingsCategory.content.canonical, .floatingPanel)
        XCTAssertTrue(appSettingsSource.contains("case .floatingPanel, .content:"))
        XCTAssertTrue(appSettingsSource.contains("contentSettings"))
        XCTAssertTrue(appSettingsSource.contains("ForEach(AppSettingsCategory.allCases)"))
        XCTAssertTrue(appSettingsSource.contains("@Binding var tokenRateFullScale: Double"))
        XCTAssertTrue(appSettingsSource.contains("TokenRateScaleSettings.displayValue(tokenRateFullScale)"))
        XCTAssertTrue(appSettingsSource.contains("buttonTitle: \"更改目录\""))
        XCTAssertTrue(appSettingsSource.contains("buttonTitle: \"打开修复工具\""))
        XCTAssertTrue(appSettingsSource.contains("threadDeleteBridge.status.connectionActionTitle"))
        XCTAssertTrue(appSettingsSource.contains("\"侧栏直接删除已迁移\""))
        XCTAssertTrue(appSettingsSource.contains("CodexLegacySessionDeletePolicy.migrationMessage"))
        XCTAssertTrue(appSettingsSource.contains("buttonTitle: \"打开会话管理\""))
        XCTAssertFalse(appSettingsSource.contains("settingsToggle(\n                    \"会话删除\""))
        XCTAssertTrue(appSettingsSource.contains("Codex++ · AGPL-3.0"))
        XCTAssertFalse(appSettingsSource.contains("删除本地数据"))
        XCTAssertTrue(dashboardSource.contains("tokenRateFullScale: $tokenRateFullScale"))
        XCTAssertTrue(dashboardSource.contains("dataSourceLabel: store.dataSourceLabel"))
        XCTAssertTrue(dashboardSource.contains("threadDeleteBridge: threadDeleteBridge"))
        XCTAssertTrue(dashboardSource.contains("selectedCategory: $appSettingsInitialCategory"))
    }

    func testFloatingPanelSettingsExposeTextWhiteSlider() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelAppearanceSettingsView.swift")
        let floatingPanel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift")
        let settingsSource = try String(contentsOf: settingsView, encoding: .utf8)
        let floatingPanelSource = try String(contentsOf: floatingPanel, encoding: .utf8)

        XCTAssertTrue(settingsSource.contains("@AppStorage(FloatingPanelAppearance.textWhiteOverrideKey)"))
        XCTAssertTrue(settingsSource.contains("title: \"字体\""))
        XCTAssertTrue(settingsSource.contains("range: -1...1"))
        XCTAssertTrue(settingsSource.contains("FloatingPanelTextTonePreference.displayText(for: floatingPanelTextWhiteOverride)"))
        XCTAssertTrue(floatingPanelSource.contains("@AppStorage(FloatingPanelAppearance.textWhiteOverrideKey)"))
        XCTAssertTrue(floatingPanelSource.contains("let textTone = FloatingPanelTextTonePreference.mode(for: floatingPanelTextWhiteOverride)"))
        XCTAssertTrue(floatingPanelSource.contains("automaticStrength: textTone.automaticStrength"))
        XCTAssertTrue(floatingPanelSource.contains("let overridePalette = textTone.manualWhite.map(FloatingPanelReadableTextPalette.init(fixedWhite:))"))
        XCTAssertTrue(floatingPanelSource.contains("appearance.textPalettes("))
        XCTAssertFalse(floatingPanelSource.contains(".environment(\\.tokenDisplayTextPalette, FloatingPanelReadableTextPalette(fixedWhite: floatingPanelTextWhiteOverride))"))
    }

    func testQuotaRefreshCadenceUsesOneSharedAppStorageKeyForDashboardAndFloatingSurfaces() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let liveRateView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let settingsView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelAppearanceSettingsView.swift")
        let quotaViews = projectRoot.appendingPathComponent("Sources/CodexTokenBar/AccountQuotaViews.swift")
        let quotaStore = projectRoot.appendingPathComponent("Sources/CodexTokenBar/AccountQuotaStore.swift")
        let tokenDisplaySurface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let liveRateSource = try String(contentsOf: liveRateView, encoding: .utf8)
        let settingsSource = try String(contentsOf: settingsView, encoding: .utf8)
        let quotaViewsSource = try String(contentsOf: quotaViews, encoding: .utf8)
        let quotaStoreSource = try String(contentsOf: quotaStore, encoding: .utf8)
        let tokenDisplaySource = try String(contentsOf: tokenDisplaySurface, encoding: .utf8)

        XCTAssertTrue(quotaStoreSource.contains("AccountQuotaRefreshCadence.storedValue"))
        XCTAssertTrue(quotaStoreSource.contains("setAutomaticRefreshInterval"))
        XCTAssertFalse(liveRateSource.contains("AccountQuotaRefreshCadencePicker"))
        XCTAssertFalse(settingsSource.contains("AccountQuotaRefreshCadencePicker"))
        XCTAssertTrue(quotaViewsSource.contains("@AppStorage(AccountQuotaRefreshCadence.storageKey)"))
        XCTAssertTrue(quotaViewsSource.contains("AccountQuotaRefreshCadencePicker"))
        XCTAssertEqual(
            AccountQuotaRefreshCadenceMenuPresentation(selectionRaw: "60").accessibilityLabel,
            "额度刷新"
        )
        XCTAssertTrue(tokenDisplaySource.contains("static func make("))
        XCTAssertTrue(tokenDisplaySource.contains("store: CodexUsageStore"))
        XCTAssertTrue(tokenDisplaySource.contains("monitor: LiveRateMonitor"))
        XCTAssertTrue(tokenDisplaySource.contains("quota: AccountQuotaStore"))
        XCTAssertTrue(tokenDisplaySource.contains("runningThreads: RunningThreadSummary"))
        XCTAssertFalse(tokenDisplaySource.contains("@AppStorage(AccountQuotaRefreshCadence.storageKey)"))
    }

    func testFloatingPanelTextTonePreferenceSplitsAutoAndManualOnOneSlider() throws {
        let strongAuto = FloatingPanelTextTonePreference.mode(for: -1)
        let weakAuto = FloatingPanelTextTonePreference.mode(for: -0.25)
        let manualBlack = FloatingPanelTextTonePreference.mode(for: 0)
        let manualWhite = FloatingPanelTextTonePreference.mode(for: 1)

        XCTAssertNil(strongAuto.manualWhite)
        XCTAssertEqual(strongAuto.automaticStrength, 1, accuracy: 0.001)
        XCTAssertNil(weakAuto.manualWhite)
        XCTAssertEqual(weakAuto.automaticStrength, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(manualBlack.manualWhite), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(manualWhite.manualWhite), 1, accuracy: 0.001)
        XCTAssertEqual(FloatingPanelTextTonePreference.displayText(for: -0.65), "自动 65%")
        XCTAssertEqual(FloatingPanelTextTonePreference.displayText(for: 0.42), "手动 42%")
    }

    func testFloatingPanelAutomaticTextStrengthStaysInBlackOrWhiteFamilies() {
        let lightStrong = FloatingPanelReadableTextPalette(
            backgroundSamples: [FloatingPanelBackgroundSample(red: 0.94, green: 0.96, blue: 1)],
            automaticStrength: 1
        )
        let lightWeak = FloatingPanelReadableTextPalette(
            backgroundSamples: [FloatingPanelBackgroundSample(red: 0.94, green: 0.96, blue: 1)],
            automaticStrength: 0
        )
        let darkStrong = FloatingPanelReadableTextPalette(
            backgroundSamples: [FloatingPanelBackgroundSample(red: 0.05, green: 0.08, blue: 0.12)],
            automaticStrength: 1
        )
        let darkWeak = FloatingPanelReadableTextPalette(
            backgroundSamples: [FloatingPanelBackgroundSample(red: 0.05, green: 0.08, blue: 0.12)],
            automaticStrength: 0
        )

        XCTAssertLessThan(lightStrong.primaryWhite, lightWeak.primaryWhite)
        XCTAssertLessThan(lightWeak.primaryWhite, 0.22)
        XCTAssertGreaterThan(darkStrong.primaryWhite, darkWeak.primaryWhite)
        XCTAssertGreaterThan(darkWeak.primaryWhite, 0.78)
    }

    func testFloatingPanelTextWhiteSliderCoversFullBlackToWhiteRange() {
        let blackPalette = FloatingPanelReadableTextPalette(fixedWhite: 0)
        let midPalette = FloatingPanelReadableTextPalette(fixedWhite: 0.5)
        let whitePalette = FloatingPanelReadableTextPalette(fixedWhite: 1)

        XCTAssertEqual(blackPalette.primaryWhite, 0, accuracy: 0.001)
        XCTAssertEqual(blackPalette.secondaryWhite, 0, accuracy: 0.001)
        XCTAssertEqual(midPalette.primaryWhite, 0.5, accuracy: 0.001)
        XCTAssertEqual(whitePalette.primaryWhite, 1, accuracy: 0.001)
        XCTAssertEqual(FloatingPanelReadableTextPalette(fixedWhite: -0.3).primaryWhite, 0, accuracy: 0.001)
        XCTAssertEqual(FloatingPanelReadableTextPalette(fixedWhite: 1.3).primaryWhite, 1, accuracy: 0.001)
    }

    func testFloatingPanelPaletteMenuDoesNotAutoDismissWhileEditing() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paletteMenu = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelPaletteMenu.swift")
        let paletteSource = try String(contentsOf: paletteMenu, encoding: .utf8)

        XCTAssertFalse(paletteSource.contains(".onChange(of: startHex)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: endHex)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: directionRaw)"))
        XCTAssertFalse(paletteSource.contains(".onChange(of: styleRaw)"))
        XCTAssertFalse(paletteSource.contains("schedulePaletteClose"))
        XCTAssertFalse(paletteSource.contains("closePaletteSoon"))
        XCTAssertTrue(paletteSource.contains("closeAction: closePaletteNow"))
    }

    func testFloatingPanelPaletteMenuKeepsDraftColorsDuringPickerDrag() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paletteMenu = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelPaletteMenu.swift")
        let paletteSource = try String(contentsOf: paletteMenu, encoding: .utf8)

        XCTAssertTrue(paletteSource.contains("@State private var startColorDraft"))
        XCTAssertTrue(paletteSource.contains("@State private var endColorDraft"))
        XCTAssertTrue(paletteSource.contains("ColorPicker(\"\", selection: draftColorBinding($startColorDraft, hex: $startHex)"))
        XCTAssertTrue(paletteSource.contains("ColorPicker(\"\", selection: draftColorBinding($endColorDraft, hex: $endHex)"))
        XCTAssertFalse(paletteSource.contains("ColorPicker(\"\", selection: colorBinding($startHex)"))
        XCTAssertFalse(paletteSource.contains("ColorPicker(\"\", selection: colorBinding($endHex)"))
        XCTAssertTrue(paletteSource.contains("draftColor.wrappedValue = newValue"))
        XCTAssertTrue(paletteSource.contains("hex.wrappedValue = nextHex"))
    }

    func testFloatingPanelPassesRadarSnapshotIntoRadarRow() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let floatingPanel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift")
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")

        let floatingPanelSource = try String(contentsOf: floatingPanel, encoding: .utf8)
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
        let componentsSource = try String(contentsOf: components, encoding: .utf8)

        XCTAssertTrue(floatingPanelSource.contains("@ObservedObject var radar: CodexRadarStore"))
        XCTAssertTrue(floatingPanelSource.contains("radarSnapshot: radar.snapshot"))
        XCTAssertTrue(floatingPanelSource.contains("radarPresentation: CodexRadarPresentationState("))
        XCTAssertTrue(floatingPanelSource.contains("staleDataDisplayed: radar.staleDataDisplayed"))
        XCTAssertTrue(floatingPanelSource.contains("feedStaleDataDisplayed: radar.feedStaleDataDisplayed"))
        XCTAssertTrue(
            FloatingPanelPresentationModel(snapshot: makeTokenDisplaySnapshot(), visibility: .default)
                .rows
                .map(\.group)
                .contains(.radar)
        )
        XCTAssertFalse(
            FloatingPanelPresentationModel(
                snapshot: makeTokenDisplaySnapshot(),
                visibility: FloatingPanelContentVisibility(
                    showRateAndBar: true,
                    showUsageStatus: true,
                    showMetrics: true,
                    showQuota: true,
                    showRadar: false
                )
            )
            .rows
            .map(\.group)
            .contains(.radar)
        )
        XCTAssertTrue(surfaceSource.contains("TokenDisplayRadarStrip(presentation: radarPresentation)"))
        XCTAssertTrue(componentsSource.contains("struct TokenDisplayRadarStrip"))
        XCTAssertTrue(componentsSource.contains("动作 \\(CodexRadarPresentationText.action(snapshot?.recommendedAction))"))
        XCTAssertTrue(componentsSource.contains("24h \\(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability24hPercent))  48h \\(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability48hPercent))"))
        XCTAssertTrue(componentsSource.contains("alignment: .leading, spacing: 2.scaled(by: displayScale)"))
        XCTAssertTrue(componentsSource.contains("alignment: .leading, spacing: 1.scaled(by: displayScale)"))
        XCTAssertTrue(componentsSource.contains("primary?.scoreDisplayText"))
        XCTAssertTrue(componentsSource.contains("tokenDisplayRadarSecondaryIQText(snapshot)"))
        XCTAssertTrue(componentsSource.contains("private func tokenDisplayRadarSecondaryIQText"))

        let radarStrip = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayRadarStrip",
            in: componentsSource,
            endingBefore: "private func tokenDisplayRadarProbabilityText"
        ))
        XCTAssertTrue(radarStrip.contains("Text(\"动作 \\(CodexRadarPresentationText.action(snapshot?.recommendedAction))\")"))
        XCTAssertTrue(radarStrip.contains("presentation.compactMarkerText"))
        XCTAssertTrue(radarStrip.contains("presentation.compactAccessibilityText"))
        XCTAssertTrue(radarStrip.contains("let actionPrimaryColor = AppTheme.radarActionRole"))
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(actionPrimaryColor)"))
        XCTAssertTrue(radarStrip.contains("let primary = snapshot?.modelIQ.primaryModelPoint"))
        XCTAssertTrue(radarStrip.contains("Text(primary?.scoreDisplayText ?? \"IQ --\")"))
        XCTAssertTrue(radarStrip.contains("tokenDisplayRadarSecondaryIQText(snapshot)"))
        XCTAssertTrue(componentsSource.contains("snapshot?.modelIQ.secondaryModelRows.prefix(2)"))
        XCTAssertTrue(radarStrip.contains(".foregroundStyle(modelPalette.primaryColor)"))
        XCTAssertFalse(radarStrip.contains("alignment: .trailing"))
    }

    func testCrowdRadarComparesThreeCompactLeadersWithoutVisualTitleOrCoverageNoise() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let crowdRow = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayCrowdRadarRow",
            in: componentsSource,
            endingBefore: "private func tokenDisplayRadarProbabilityText"
        ))

        XCTAssertTrue(crowdRow.contains("let leaders = Array(crowd.rankedModels.prefix(3))"))
        XCTAssertEqual(
            componentsSource.components(separatedBy: "TokenDisplayRadarColumns(dividerColor: textPalette.dividerColor)").count - 1,
            2
        )
        XCTAssertTrue(componentsSource.contains("let leadingWidth = contentWidth * 0.37"))
        XCTAssertFalse(crowdRow.contains("Text(\"众测\")"))
        XCTAssertFalse(crowdRow.contains("Label(\"众测雷达\", systemImage:"))
        XCTAssertTrue(crowdRow.contains("resultView(leaders.first, position: 1)"))
        XCTAssertTrue(crowdRow.contains("resultView(leaders.dropFirst().first, position: 2)"))
        XCTAssertTrue(crowdRow.contains("resultView(leaders.dropFirst(2).first, position: 3)"))
        XCTAssertTrue(crowdRow.contains("· \\($0.scorePassed)/\\($0.scoreSamples)"))
        XCTAssertFalse(crowdRow.contains("· \\($0.scoreSamples)判"))
        XCTAssertFalse(crowdRow.contains("· \\($0.graded)判"))
        XCTAssertFalse(crowdRow.contains("crowd.taskCount"))
        XCTAssertFalse(crowdRow.contains("crowd.cellCount"))
        XCTAssertFalse(crowdRow.contains("crowd.contributorCount"))
        XCTAssertFalse(crowdRow.contains("crowd.pendingGrades"))
        XCTAssertFalse(crowdRow.contains("通过率"))
        XCTAssertTrue(crowdRow.contains(".accessibilityLabel(\"众测雷达\")"))
    }

    func testFloatingPanelPresentationKeepsNoQuotaStatesCountSafe() {
        let pendingSnapshot = makeTokenDisplaySnapshot(quota: .empty)
        var failedQuota = AccountQuotaSnapshot.empty
        failedQuota.status = "额度读取失败"
        let failedSnapshot = makeTokenDisplaySnapshot(quota: failedQuota)
        let visibility = FloatingPanelContentVisibility(
            showRateAndBar: false,
            showUsageStatus: true,
            showMetrics: false,
            showQuota: false,
            showRadar: false
        )

        let pendingModel = FloatingPanelPresentationModel(snapshot: pendingSnapshot, visibility: visibility)
        let failedModel = FloatingPanelPresentationModel(snapshot: failedSnapshot, visibility: visibility)

        XCTAssertEqual(pendingModel.standaloneUsageStatus, "读取中")
        XCTAssertEqual(failedModel.standaloneUsageStatus, "读取失败")
        XCTAssertFalse(pendingModel.standaloneUsageStatus?.contains("卡") ?? true)
        XCTAssertFalse(failedModel.standaloneUsageStatus?.contains("到期") ?? true)
    }

    func testFloatingPanelPresentationShowsOnlySevenDayQuotaWhenFiveHourIsAbsent() {
        let quota = AccountQuotaSnapshot(
            fiveHour: nil,
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 0,
                resetsAt: Date(timeIntervalSince1970: 20_000)
            ),
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let model = FloatingPanelPresentationModel(
            snapshot: makeTokenDisplaySnapshot(quota: quota),
            visibility: FloatingPanelContentVisibility(
                showRateAndBar: false,
                showUsageStatus: false,
                showMetrics: false,
                showQuota: true,
                showRadar: false
            )
        )

        XCTAssertFalse(model.accessibilityParts.contains { $0.contains("5 小时额度") })
        XCTAssertTrue(model.accessibilityParts.contains { $0.contains("7 天额度剩余 100%") })
    }

    func testStandaloneUsageStatusLineKeepsPlainTextStyleWithoutBackground() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let standaloneLine = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayUsageStatusLine",
            in: componentsSource,
            endingBefore: "struct TokenDisplayRadarStrip"
        ))

        XCTAssertFalse(standaloneLine.contains(".background("))
        XCTAssertFalse(standaloneLine.contains("Capsule()"))
    }

    func testFloatingPanelTextUsesReadableToneIncludingQuotaSegments() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let floatingPanel = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift")
        let controls = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelControls.swift")
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let floatingPanelSource = try String(contentsOf: floatingPanel, encoding: .utf8)
        let controlsSource = try String(contentsOf: controls, encoding: .utf8)
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
        let standaloneLine = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayUsageStatusLine",
            in: componentsSource,
            endingBefore: "struct TokenDisplayRateBar"
        ))
        let rateBar = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayRateBar",
            in: componentsSource,
            endingBefore: "struct TokenDisplayMetric"
        ))
        let metric = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayMetric",
            in: componentsSource,
            endingBefore: "struct TokenGlassBackground"
        ))
        let quotaSegment = try XCTUnwrap(sourceBlock(
            named: "TokenQuotaMiniSegment",
            in: componentsSource,
            endingBefore: "struct TokenDisplayUsageStatusLine"
        ))

        XCTAssertTrue(floatingPanelSource.contains("let textTone = FloatingPanelTextTonePreference.mode(for: floatingPanelTextWhiteOverride)"))
        XCTAssertTrue(floatingPanelSource.contains("appearance.textPalettes("))
        XCTAssertTrue(floatingPanelSource.contains("automaticStrength: textTone.automaticStrength"))
        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayTextPalette, baseTextPalette)"))
        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayRowTextPalettes, rowTextPalettes)"))
        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayMetricTextPalettes, metricTextPalettes)"))
        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayEmbeddedUsageStatusTextPalette, embeddedUsageStatusTextPalette)"))
        XCTAssertTrue(floatingPanelSource.contains(".environment(\\.tokenDisplayStandaloneUsageStatusTextPalette, standaloneUsageStatusTextPalette)"))
        XCTAssertTrue(controlsSource.contains("@Environment(\\.tokenDisplayTextPalette) private var textPalette"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayTextPalette) private var textPalette"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayRowTextPalettes) private var rowTextPalettes"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayMetricTextPalettes) private var metricTextPalettes"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayEmbeddedUsageStatusTextPalette) private var embeddedUsageStatusTextPalette"))
        XCTAssertTrue(surfaceSource.contains("@Environment(\\.tokenDisplayStandaloneUsageStatusTextPalette) private var standaloneUsageStatusTextPalette"))
        XCTAssertTrue(rateBar.contains("let contentTop = max(0, (height - contentHeight) / 2)"))
        XCTAssertTrue(rateBar.contains("let barCenterY = usageStatus == nil"))
        XCTAssertFalse(rateBar.contains("let barCenterY = 22.scaled(by: displayScale)"))
        XCTAssertFalse(surfaceSource.contains(".offset(x: 3.scaled(by: displayScale), y: 1.5.scaled(by: displayScale))"))
        XCTAssertFalse(surfaceSource.contains(".offset(y: 2.scaled(by: displayScale))"))
        XCTAssertTrue(rateBar.contains("let statusPalette = embeddedUsageStatusTextPalette ?? textPalette"))
        XCTAssertTrue(standaloneLine.contains("size: 9.5.scaled(by: displayScale)"))
        XCTAssertTrue(rateBar.contains("size: 9.1.scaled(by: displayScale)"))
        XCTAssertTrue(standaloneLine.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertTrue(rateBar.contains(".foregroundStyle(statusPalette.primaryColor)"))
        XCTAssertTrue(metric.contains(".foregroundStyle(textPalette.secondaryColor)"))
        XCTAssertTrue(metric.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertTrue(quotaSegment.contains("@Environment(\\.tokenDisplayTextPalette) private var textPalette"))
        XCTAssertTrue(quotaSegment.contains(".foregroundStyle(textPalette.primaryColor)"))
        XCTAssertFalse(quotaSegment.contains(".foregroundStyle(.primary.opacity(0.82))"))
    }

    func testFloatingPanelRadarModelLabelStaysReadableBesideIQ() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let radarStrip = try XCTUnwrap(sourceBlock(
            named: "TokenDisplayRadarStrip",
            in: componentsSource,
            endingBefore: "private func tokenDisplayRadarProbabilityText"
        ))

        XCTAssertTrue(radarStrip.contains("size: 11.8.scaled(by: displayScale)"))
        XCTAssertTrue(radarStrip.contains("size: 8.4.scaled(by: displayScale)"))
        XCTAssertTrue(radarStrip.contains(".minimumScaleFactor(0.82)"))
        XCTAssertFalse(radarStrip.contains("size: 7.7.scaled(by: displayScale)"))
        XCTAssertFalse(radarStrip.contains(".minimumScaleFactor(0.66)"))
    }

    func testFloatingPanelQuotaBarsUseSlightlySquarerShapeAndAlignedMetrics() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let metrics = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelMetrics.swift")
        let componentsSource = try String(contentsOf: components, encoding: .utf8)
        let surfaceSource = try String(contentsOf: surface, encoding: .utf8)
        let metricsSource = try String(contentsOf: metrics, encoding: .utf8)
        let quotaSegment = try XCTUnwrap(sourceBlock(
            named: "TokenQuotaMiniSegment",
            in: componentsSource,
            endingBefore: "struct TokenDisplayUsageStatusLine"
        ))
        guard let metricRowStart = surfaceSource.range(of: "private var metricRow: some View")?.lowerBound,
              let metricRowEnd = surfaceSource[metricRowStart...].range(of: "\n    }\n}")?.lowerBound
        else {
            XCTFail("TokenDisplayCard must keep a metricRow block")
            return
        }
        let metricRow = String(surfaceSource[metricRowStart..<metricRowEnd])

        XCTAssertTrue(quotaSegment.contains("quotaSegmentShape(height: proxy.size.height)"))
        XCTAssertTrue(quotaSegment.contains("RoundedRectangle(cornerRadius: quotaSegmentCornerRadius"))
        XCTAssertFalse(quotaSegment.contains("Capsule()\n                        .fill(floatingTrackColor)"))
        XCTAssertTrue(metricsSource.contains("static let metricOutset: CGFloat = 14.5"))
        XCTAssertTrue(metricsSource.contains("static let metricTodayNudge: CGFloat = -4.5"))
        XCTAssertTrue(metricsSource.contains("static let metricRequestsNudge: CGFloat = 8"))
        XCTAssertTrue(metricsSource.contains("static func metricRequestsNudge(for requestCount: Int) -> CGFloat"))
        XCTAssertTrue(metricRow.contains("FloatingTokenPanelMetrics.metricTodayOffset("))
        XCTAssertTrue(metricRow.contains("FloatingTokenPanelMetrics.metricRequestsOffset("))
        XCTAssertEqual(
            FloatingTokenPanelMetrics.metricRequestsNudge(for: 99),
            FloatingTokenPanelMetrics.metricRequestsNudge + FloatingTokenPanelMetrics.metricRequestsDigitCompensation,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloatingTokenPanelMetrics.metricRequestsNudge(for: 999),
            FloatingTokenPanelMetrics.metricRequestsNudge,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloatingTokenPanelMetrics.metricRequestsNudge(for: 1_000),
            FloatingTokenPanelMetrics.metricRequestsNudge - FloatingTokenPanelMetrics.metricRequestsDigitCompensation,
            accuracy: 0.001
        )
    }

    func testPagedRowArrowsUseCompactVisualsAtTheOuterEdge() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurface.swift")
        let source = try String(contentsOf: surface, encoding: .utf8)
        let panel = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingTokenPanel.swift"),
            encoding: .utf8
        )
        let editor = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelStructureEditor.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".padding(.horizontal, -10.scaled(by: displayScale))"))
        XCTAssertTrue(source.contains(".padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * displayScale)"))
        XCTAssertFalse(panel.contains(".padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * scale)"))
        XCTAssertFalse(editor.contains(".padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * previewScale)"))
        XCTAssertTrue(source.contains(".scaleEffect(x: 0.58, y: 0.92, anchor: .center)"))
        XCTAssertTrue(source.contains("let edgeAlignment: Alignment = delta < 0 ? .leading : .trailing"))
        XCTAssertTrue(source.contains(".overlay(alignment: edgeAlignment)"))
        XCTAssertFalse(source.contains(".offset(x: (delta < 0 ? -17 : 17).scaled(by: displayScale))"))
        XCTAssertTrue(source.contains("width: 14.scaled(by: displayScale)"))
        XCTAssertTrue(source.contains("height: 20.scaled(by: displayScale)"))
        XCTAssertTrue(source.contains("width: 48.scaled(by: displayScale)"))
        XCTAssertTrue(source.contains("height: 24.scaled(by: displayScale)"))
        XCTAssertTrue(source.contains("Rectangle()\n                .fill(Color.black.opacity(0.001))"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)\n        .contentShape(Rectangle())"))
        XCTAssertTrue(source.contains("if row.isPaged {"))
        XCTAssertTrue(source.contains("showsGlyph: visibility.showPageNavigationArrows"))
        XCTAssertTrue(source.contains(".opacity(showsGlyph ? 1 : 0)"))

        let dashboard = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(dashboard.contains("floatingPanelShowPageNavigationArrows ? \"1\" : \"0\""))
    }

    func testStructureEditorShowsInsertionPreviewAndAcceptsHiddenDrops() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editor = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingPanelStructureEditor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(editor.contains("case gap(targetID: String, placement: FloatingPanelContentDropPlacement)"))
        XCTAssertTrue(editor.contains("isTarget ? AppTheme.accentBlue.opacity(0.12)"))
        XCTAssertTrue(editor.contains("FloatingStructureHiddenDropDelegate"))
        XCTAssertTrue(editor.contains("Text(isDropTarget ? \"松手即可隐藏\" : \"拖到这里隐藏\")"))
        XCTAssertTrue(editor.contains("canDropOnRow"))
        XCTAssertTrue(editor.contains("canDropIntoGap"))
    }

    private func sourceBlock(named name: String, in source: String, endingBefore marker: String) -> String? {
        guard let start = source.range(of: "struct \(name)")?.lowerBound,
              let end = source[start...].range(of: marker)?.lowerBound
        else {
            return nil
        }
        return String(source[start..<end])
    }

    private func makeTokenDisplaySnapshot(
        quota: AccountQuotaSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: Date(timeIntervalSince1970: 2_000)),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 20_000)),
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ),
        usagePrecision: DashboardUsagePrecision = .precise,
        usageReadStatus: String = "",
        runningThreads: RunningThreadSummary = .unavailable
    ) -> TokenDisplaySnapshot {
        TokenDisplaySnapshot(
            title: "全会话实时",
            status: "输出中",
            rate: 12.3,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            usagePrecision: usagePrecision,
            usageReadStatus: usageReadStatus,
            quota: quota,
            runningThreads: runningThreads,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
