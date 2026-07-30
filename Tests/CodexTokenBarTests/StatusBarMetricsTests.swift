import XCTest
@testable import CodexTokenBar

final class StatusBarMetricsTests: XCTestCase {
    func testMetricRawIDsAndDefaultsStayStable() {
        XCTAssertEqual(
            StatusBarMetricID.allCases.map(\.rawValue),
            ["rate", "fiveHour", "sevenDay", "iq", "today", "total", "requests", "running", "unread"]
        )
        XCTAssertEqual(
            StatusBarMetricConfiguration.default.visibleMetricIDs,
            [.rate, .fiveHour, .sevenDay, .iq]
        )
        XCTAssertEqual(
            StatusBarMetricConfiguration.defaultOrderRaw,
            "rate,fiveHour,sevenDay,iq,today,total,requests,running,unread"
        )
        XCTAssertEqual(
            StatusBarMetricConfiguration.defaultSelectionRaw,
            "rate,fiveHour,sevenDay,iq"
        )
        XCTAssertEqual(StatusBarMetricConfiguration.default.labelStyle, .compact)
    }

    func testConfigurationPreservesKnownUserOrderAndRepairsDuplicatesAndUnknownIDs() {
        let configuration = StatusBarMetricConfiguration(
            orderRaw: " unread,rate,unknown,unread,iq ",
            selectionRaw: "iq,unread,unknown,iq",
            showsIcon: false
        )

        XCTAssertEqual(
            configuration.orderedMetricIDs,
            [.unread, .rate, .iq, .fiveHour, .sevenDay, .today, .total, .requests, .running]
        )
        XCTAssertEqual(configuration.visibleMetricIDs, [.unread, .iq])
        XCTAssertFalse(configuration.showsIcon)
    }

    func testPresentationUsesConfiguredOrderAndExactUltraShortLabels() {
        let configuration = StatusBarMetricConfiguration(
            orderedMetricIDs: [.fiveHour, .sevenDay, .iq, .running, .unread, .today, .total, .requests, .rate],
            selectedMetricIDs: Set(StatusBarMetricID.allCases),
            showsIcon: true
        )
        let values = makeValues(
            rate: 42.4,
            fiveHour: 76,
            sevenDay: 42,
            iq: 104,
            today: 84_000,
            total: 1_200_000,
            requests: 42,
            running: RunningThreadSummary(
                main: 1,
                subagents: 2,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                freshness: .fresh
            ),
            unread: 2
        )

        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: configuration
        )

        XCTAssertEqual(
            presentation.text,
            "⁵ʰ76% · ⁷ᵈ42% · IQ104 · 跑3 · 未2 · 今84K · 总1.2M · 次42 · 42.4/s"
        )
        XCTAssertEqual(
            presentation.segments.map(\.id),
            [.fiveHour, .sevenDay, .iq, .running, .unread, .today, .total, .requests, .rate]
        )
    }

    func testTrueZeroValuesDisplayAsZeroWhileMissingValuesDisplayDash() {
        let configuration = StatusBarMetricConfiguration(
            orderedMetricIDs: [.fiveHour, .sevenDay, .iq, .today, .total, .requests, .rate],
            selectedMetricIDs: [.fiveHour, .sevenDay, .iq, .today, .total, .requests, .rate],
            showsIcon: false
        )
        let values = makeValues(
            rate: nil,
            fiveHour: 0,
            sevenDay: nil,
            iq: 0,
            today: 0,
            total: nil,
            requests: 0
        )

        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: configuration
        )

        XCTAssertEqual(presentation.text, "⁵ʰ0% · ⁷ᵈ— · IQ0 · 今0 · 总— · 次0 · —")
        XCTAssertEqual(
            presentation.segments.map(\.id),
            [.fiveHour, .sevenDay, .iq, .today, .total, .requests, .rate]
        )
    }

    func testRunningAndUnreadStayVisibleAtZeroAndUseDashOnlyWhenUnavailable() {
        let configuration = StatusBarMetricConfiguration(
            orderedMetricIDs: [.running, .unread],
            selectedMetricIDs: [.running, .unread],
            showsIcon: false
        )

        XCTAssertEqual(
            StatusBarMetricsPresentation.make(
                values: makeValues(running: .unavailable, unread: nil),
                configuration: configuration
            ).text,
            "跑— · 未—"
        )
        XCTAssertEqual(
            StatusBarMetricsPresentation.make(
                values: makeValues(running: .unavailable, unread: 4),
                configuration: configuration
            ).text,
            "跑— · 未4"
        )
        XCTAssertEqual(
            StatusBarMetricsPresentation.make(
                values: makeValues(
                    running: RunningThreadSummary(
                        main: 2,
                        subagents: 0,
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        freshness: .stale
                    ),
                    unread: 0
                ),
                configuration: configuration
            ).text,
            "跑2 · 未0"
        )
        XCTAssertEqual(
            StatusBarMetricsPresentation.make(
                values: makeValues(
                    running: RunningThreadSummary(
                        main: 0,
                        subagents: 0,
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        freshness: .fresh
                    ),
                    unread: 0
                ),
                configuration: configuration
            ).text,
            "跑0 · 未0"
        )
    }

    func testSnapshotConversionOmitsUsageWhenPrecisionIsMetadataOnly() {
        let snapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "读取中",
            rate: 1,
            consumedTokens: 1_200_000,
            todayTokens: 84_000,
            todayRequests: 42,
            usagePrecision: .metadataOnly,
            quota: AccountQuotaSnapshot(
                fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 100, resetsAt: nil),
                sevenDay: nil
            ),
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )

        let values = StatusBarMetricValues(
            snapshot: snapshot,
            radar: CodexRadarPresentationState(),
            unreadThreadCount: 0
        )
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: [.today, .total, .requests, .fiveHour],
                selectedMetricIDs: [.today, .total, .requests, .fiveHour],
                showsIcon: true
            )
        )

        XCTAssertNil(values.todayTokens)
        XCTAssertNil(values.totalTokens)
        XCTAssertNil(values.requests)
        XCTAssertEqual(presentation.text, "今— · 总— · 次— · ⁵ʰ0%")
    }

    func testLabelStylesChangePrefixesWithoutChangingValuesOrOrder() {
        let values = makeValues(
            fiveHour: 72,
            sevenDay: nil,
            iq: 104,
            today: 84_000,
            running: RunningThreadSummary(
                main: 0,
                subagents: 0,
                updatedAt: Date(timeIntervalSince1970: 4_000),
                freshness: .fresh
            )
        )
        let order: [StatusBarMetricID] = [.fiveHour, .sevenDay, .iq, .today, .running]
        let selection = Set(order)

        let full = StatusBarMetricsPresentation.make(
            values: values,
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: order,
                selectedMetricIDs: selection,
                showsIcon: false,
                labelStyle: .full
            )
        )
        let compact = StatusBarMetricsPresentation.make(
            values: values,
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: order,
                selectedMetricIDs: selection,
                showsIcon: false,
                labelStyle: .compact
            )
        )
        let hidden = StatusBarMetricsPresentation.make(
            values: values,
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: order,
                selectedMetricIDs: selection,
                showsIcon: false,
                labelStyle: .hidden
            )
        )

        XCTAssertEqual(full.text, "5h72% · 7d— · 模型 IQ104 · 今日84K · 运行0")
        XCTAssertEqual(compact.text, "⁵ʰ72% · ⁷ᵈ— · IQ104 · 今84K · 跑0")
        XCTAssertEqual(hidden.text, "72% · — · 104 · 84K · 0")
    }

    func testSummarySectionRawIDsDefaultsAndUserOrderStayStable() {
        XCTAssertEqual(
            StatusSummarySectionID.allCases.map(\.rawValue),
            ["overview", "usage", "quota", "running", "unread", "radar", "crowdRadar"]
        )
        XCTAssertEqual(
            StatusSummaryConfiguration.default.visibleSectionIDs,
            [.overview, .usage, .quota, .running, .unread, .radar, .crowdRadar]
        )

        let configuration = StatusSummaryConfiguration(
            orderRaw: "crowdRadar,usage,unknown,crowdRadar",
            selectionRaw: "usage,crowdRadar,unknown"
        )

        XCTAssertEqual(
            configuration.orderedSectionIDs,
            [.crowdRadar, .usage, .overview, .quota, .running, .unread, .radar]
        )
        XCTAssertEqual(configuration.visibleSectionIDs, [.crowdRadar, .usage])
    }

    func testSummaryEmptySelectionRemainsEmptyInsteadOfRestoringDefaults() {
        let configuration = StatusSummaryConfiguration(
            orderRaw: StatusSummaryConfiguration.defaultOrderRaw,
            selectionRaw: ""
        )

        XCTAssertTrue(configuration.visibleSectionIDs.isEmpty)
    }

    func testPendingSettingsRouteSurvivesUntilDashboardConsumesIt() {
        let suiteName = "StatusBarMetricsTests.route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let notificationCenter = NotificationCenter()

        AppSettingsRouteRequest.request(
            .statusBar,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(AppSettingsRouteRequest.consume(defaults: defaults), .statusBar)
        XCTAssertNil(AppSettingsRouteRequest.consume(defaults: defaults))
    }

    private func makeValues(
        rate: Double? = 0,
        fiveHour: Int? = nil,
        sevenDay: Int? = nil,
        iq: Double? = nil,
        today: Int? = nil,
        total: Int? = nil,
        requests: Int? = nil,
        running: RunningThreadSummary = .unavailable,
        unread: Int? = 0
    ) -> StatusBarMetricValues {
        StatusBarMetricValues(
            rate: rate,
            fiveHourRemainingPercent: fiveHour,
            sevenDayRemainingPercent: sevenDay,
            iqScore: iq,
            todayTokens: today,
            totalTokens: total,
            requests: requests,
            runningThreads: running,
            unreadThreadCount: unread
        )
    }
}
