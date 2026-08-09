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
        XCTAssertEqual(StatusBarMetricID.iq.title, "今日模型榜")
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
            rankings: sampleRankings,
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
            "5H76% · 7D42% · 1 Sol·XH / 2 Luna·H · 跑3 · 未2 · 今84K · 总1.2M · 次42 · 42.4/s"
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
            today: 0,
            total: nil,
            requests: 0
        )

        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: configuration
        )

        XCTAssertFalse(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.text, "5H0% · 7D— · 1 — / 2 — · 今0 · 总— · 次0 · —")
        XCTAssertEqual(
            presentation.segments.map(\.id),
            [.fiveHour, .sevenDay, .iq, .today, .total, .requests, .rate]
        )
    }

    func testIsolatedFiveHourAbsenceHidesOnlyFiveHourMetric() {
        let values = makeValues(fiveHour: nil, sevenDay: 42)
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: quotaOnlyConfiguration
        )

        XCTAssertTrue(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.segments.map(\.id), [.sevenDay])
        XCTAssertEqual(presentation.text, "7D42%")
    }

    func testMalformedFiveHourRemainsVisibleAsDashWhenSevenDayIsMeasured() {
        let values = makeValues(
            fiveHour: nil,
            sevenDay: 42,
            fiveHourAvailability: .unavailable
        )
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: quotaOnlyConfiguration
        )

        XCTAssertFalse(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.segments.map(\.id), [.fiveHour, .sevenDay])
        XCTAssertEqual(presentation.text, "5H— · 7D42%")
    }

    func testTotalQuotaFailureKeepsBothUnavailableMetrics() {
        let values = makeValues(fiveHour: nil, sevenDay: nil)
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: quotaOnlyConfiguration
        )

        XCTAssertFalse(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.segments.map(\.id), [.fiveHour, .sevenDay])
        XCTAssertEqual(presentation.text, "5H— · 7D—")
    }

    func testFiveHourTrueZeroRemainsVisibleWhenSevenDayIsUnavailable() {
        let values = makeValues(fiveHour: 0, sevenDay: nil)
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: quotaOnlyConfiguration
        )

        XCTAssertFalse(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.segments.map(\.id), [.fiveHour, .sevenDay])
        XCTAssertEqual(presentation.text, "5H0% · 7D—")
    }

    func testTodayModelRankingUsesShortFamiliesAndEffortCodes() {
        let cases = [
            ("gpt-5.6-sol", "max", "Sol·MAX"),
            ("GPT-5.6 Luna", "xhigh", "Luna·XH"),
            ("gpt-5.6-terra", "high", "Terra·H"),
            ("Sol", "medium", "Sol·M"),
            ("Luna", "low", "Luna·L"),
            ("Terra", "minimal", "Terra·MIN"),
            ("Sol", "ultra", "Sol·U"),
            ("gpt-5.5", "xhigh", "5.5·XH"),
            ("gpt-5.4", "high", "5.4·H"),
        ]

        for (model, effort, expected) in cases {
            XCTAssertEqual(
                StatusBarModelRankingEntry(modelName: model, reasoningEffort: effort).compactText,
                expected
            )
        }

        let presentation = StatusBarMetricsPresentation.make(
            values: makeValues(rankings: [
                StatusBarModelRankingEntry(modelName: "gpt-5.6-sol", reasoningEffort: "xhigh")
            ]),
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: [.iq],
                selectedMetricIDs: [.iq],
                showsIcon: false
            )
        )
        XCTAssertEqual(presentation.text, "1 Sol·XH / 2 —")
        XCTAssertTrue(presentation.accessibilityValue.contains("思考强度 xhigh"))
    }

    func testSnapshotConversionUsesRadarTopTwoWithoutIQScores() throws {
        let radarSnapshot = try JSONDecoder.codexRadar.decode(
            CodexRadarSnapshot.self,
            from: Data(#"""
            {
              "timezone": "Asia/Shanghai",
              "model_iq": {
                "latest": {
                  "date": "2026-07-31",
                  "score": 130,
                  "tasks": 10,
                  "valid_tasks": 10,
                  "model": "gpt-5.6-luna",
                  "reasoning_effort": "high"
                },
                "comparisons": {
                  "sol": {
                    "label": "GPT-5.6 Sol xhigh",
                    "model": "gpt-5.6-sol",
                    "reasoning_effort": "xhigh",
                    "latest": {
                      "date": "2026-07-31",
                      "score": 150,
                      "tasks": 10,
                      "valid_tasks": 10,
                      "model": "gpt-5.6-sol",
                      "reasoning_effort": "xhigh"
                    }
                  },
                  "terra": {
                    "label": "GPT-5.6 Terra max",
                    "model": "gpt-5.6-terra",
                    "reasoning_effort": "max",
                    "latest": {
                      "date": "2026-07-31",
                      "score": 120,
                      "tasks": 10,
                      "valid_tasks": 10,
                      "model": "gpt-5.6-terra",
                      "reasoning_effort": "max"
                    }
                  }
                }
              }
            }
            """#.utf8)
        )
        let tokenSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            quota: .empty,
            updatedAt: .distantPast
        )

        let values = StatusBarMetricValues(
            snapshot: tokenSnapshot,
            radar: CodexRadarPresentationState(snapshot: radarSnapshot),
            unreadThreadCount: 0,
            now: july30_2026_1630UTC,
            calendar: utcCalendar
        )

        XCTAssertEqual(values.modelRankings.map(\.compactText), ["Sol·XH", "Luna·H"])
        XCTAssertFalse(
            values.modelRankings.map(\.compactText).contains { $0.localizedCaseInsensitiveContains("IQ") }
        )

        let staleValues = StatusBarMetricValues(
            snapshot: tokenSnapshot,
            radar: CodexRadarPresentationState(
                snapshot: radarSnapshot,
                staleDataDisplayed: true
            ),
            unreadThreadCount: 0,
            now: july31_2026UTC,
            calendar: utcCalendar
        )
        XCTAssertTrue(staleValues.modelRankings.isEmpty)
    }

    func testTodayModelRankingRejectsStaleAndZeroSampleRowsButKeepsMeasuredZero() throws {
        let radarSnapshot = try JSONDecoder.codexRadar.decode(
            CodexRadarSnapshot.self,
            from: Data(#"""
            {
              "model_iq": {
                "latest": {
                  "date": "2026-07-31",
                  "score": 0,
                  "tasks": 1,
                  "valid_tasks": 1,
                  "model": "gpt-5.6-sol",
                  "reasoning_effort": "ultra"
                },
                "comparisons": {
                  "stale": {
                    "label": "GPT-5.6 Luna max",
                    "model": "gpt-5.6-luna",
                    "reasoning_effort": "max",
                    "latest": {
                      "date": "2026-07-30",
                      "score": 999,
                      "tasks": 10,
                      "valid_tasks": 10,
                      "model": "gpt-5.6-luna",
                      "reasoning_effort": "max"
                    }
                  },
                  "pending": {
                    "label": "GPT-5.6 Terra xhigh",
                    "model": "gpt-5.6-terra",
                    "reasoning_effort": "xhigh",
                    "latest": {
                      "date": "2026-07-31",
                      "score": 500,
                      "status": "pending",
                      "tasks": 0,
                      "valid_tasks": 0,
                      "model": "gpt-5.6-terra",
                      "reasoning_effort": "xhigh"
                    }
                  }
                }
              }
            }
            """#.utf8)
        )
        let tokenSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            quota: .empty,
            updatedAt: .distantPast
        )

        let values = StatusBarMetricValues(
            snapshot: tokenSnapshot,
            radar: CodexRadarPresentationState(snapshot: radarSnapshot),
            unreadThreadCount: 0,
            now: july31_2026UTC,
            calendar: utcCalendar
        )

        XCTAssertEqual(values.modelRankings.map(\.compactText), ["Sol·U"])
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
        XCTAssertEqual(presentation.text, "今— · 总— · 次— · 5H0%")
    }

    func testQuotaReadFailureShowsDashesInsteadOfStaleCachedPercentages() {
        let snapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            quota: AccountQuotaSnapshot(
                fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: nil),
                sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 40, resetsAt: nil),
                diagnostics: [.staleCachedData(source: .accountQuota)]
            ),
            updatedAt: .distantPast
        )
        let values = StatusBarMetricValues(
            snapshot: snapshot,
            radar: CodexRadarPresentationState(),
            unreadThreadCount: 0
        )

        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: quotaOnlyConfiguration
        )

        XCTAssertFalse(values.fiveHourWindowOfficiallyAbsent)
        XCTAssertEqual(presentation.text, "5H— · 7D—")
    }

    func testLabelStylesChangePrefixesWithoutChangingValuesOrOrder() {
        let values = makeValues(
            fiveHour: 72,
            sevenDay: nil,
            rankings: sampleRankings,
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

        XCTAssertEqual(full.text, "5h72% · 7d— · 1 Sol·XH / 2 Luna·H · 今日84K · 运行0")
        XCTAssertEqual(compact.text, "5H72% · 7D— · 1 Sol·XH / 2 Luna·H · 今84K · 跑0")
        XCTAssertEqual(hidden.text, "72% · — · 1 Sol·XH / 2 Luna·H · 84K · 0")
        XCTAssertEqual(full.columns.first?.top.text, "5h 72%")
        XCTAssertEqual(full.columns.first?.bottom.text, "7d —")
        XCTAssertEqual(compact.columns.first?.top.text, "5 72%")
        XCTAssertEqual(compact.columns.first?.bottom.text, "7 —")
        XCTAssertEqual(hidden.columns.first?.top.text, "72%")
        XCTAssertEqual(hidden.columns.first?.bottom.text, "—")
        XCTAssertEqual(compact.columns[1].top.text, "1 Sol·XH")
        XCTAssertEqual(compact.columns[1].bottom.text, "2 Luna·H")
        XCTAssertEqual(compact.columns[2].top.text, "今84K")
        XCTAssertEqual(compact.columns[2].bottom.text, "跑0")
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

    func testLegacyContentSettingsRouteRedirectsToUnifiedFloatingPage() {
        let suiteName = "StatusBarMetricsTests.legacy-content-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("content", forKey: AppSettingsRouteRequest.pendingCategoryKey)

        XCTAssertEqual(AppSettingsRouteRequest.consume(defaults: defaults), .floatingPanel)
        XCTAssertNil(AppSettingsRouteRequest.consume(defaults: defaults))
    }

    private func makeValues(
        rate: Double? = 0,
        fiveHour: Int? = nil,
        sevenDay: Int? = nil,
        fiveHourAvailability: AccountQuotaWindowAvailability? = nil,
        rankings: [StatusBarModelRankingEntry] = [],
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
            fiveHourAvailability: fiveHourAvailability,
            modelRankings: rankings,
            todayTokens: today,
            totalTokens: total,
            requests: requests,
            runningThreads: running,
            unreadThreadCount: unread
        )
    }

    private var quotaOnlyConfiguration: StatusBarMetricConfiguration {
        StatusBarMetricConfiguration(
            orderedMetricIDs: [.fiveHour, .sevenDay],
            selectedMetricIDs: [.fiveHour, .sevenDay],
            showsIcon: false
        )
    }

    private var sampleRankings: [StatusBarModelRankingEntry] {
        [
            StatusBarModelRankingEntry(modelName: "gpt-5.6-sol", reasoningEffort: "xhigh"),
            StatusBarModelRankingEntry(modelName: "gpt-5.6-luna", reasoningEffort: "high"),
        ]
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var july31_2026UTC: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 31))!
    }

    private var july30_2026_1630UTC: Date {
        utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 30,
            hour: 16,
            minute: 30
        ))!
    }
}
