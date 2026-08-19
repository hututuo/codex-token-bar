import XCTest
@testable import CodexTokenBar

final class CodexRadarModelsTests: XCTestCase {
    func testCompactRadarPresentationLocalizesActionsAndKeepsModelReasoningEffort() {
        XCTAssertEqual(CodexRadarPresentationText.action("wait"), "等待")
        XCTAssertEqual(CodexRadarPresentationText.action("run"), "运行")
        for rawValue in ["Use Windows", "use_window", "use-window", "use windows", "use_remaining_tokens"] {
            XCTAssertEqual(CodexRadarPresentationText.action(rawValue), "速登窗口")
        }
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("GPT-5.6 Sol max"), "Sol max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("GPT-5.6 Luna max"), "Luna max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("GPT-5.6 Terra max"), "Terra max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("GPT-5.6 Sol xhigh"), "Sol xhigh")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("GPT-5.6 Sol ultra"), "Sol ultra")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DeepSeek V4 Flash max"), "DS F max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DeepSeek V4 Flash high"), "DS F high")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DeepSeek V4 Pro max"), "DS P max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DeepSeek R1"), "DS R1")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DSH F max"), "DSH F max")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DSH-V4-Pro high"), "DSH P high")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("DSH R1 medium"), "DSH R1 medium")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("grok-4.6 xhigh"), "G4.6 XH")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("k3 high"), "K3 H")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName("glm-5.3 max"), "GLM5.3 max")
    }

    func testCurrentSolMaxScoreOutranksOlderTerraAndKeepsItsEffortInCompactLabel() {
        let solMax = Self.modelIQPoint(
            score: 150,
            reasoningEffort: "max",
            costUsd: 35,
            model: "gpt-5.6-sol"
        )
        let terraMax = Self.modelIQPoint(
            score: 135,
            reasoningEffort: "max",
            costUsd: 30,
            model: "gpt-5.6-terra"
        )
        let modelIQ = CodexRadarModelIQ(
            latest: solMax,
            recentDays: [solMax],
            comparisons: [
                "terra": CodexRadarModelIQComparison(
                    label: "GPT-5.6 Terra max",
                    model: "gpt-5.6-terra",
                    reasoningEffort: "max",
                    latest: terraMax,
                    recentDays: [terraMax]
                )
            ],
            quotaCalibration: nil,
            quotaRadar: nil,
            quotaCheck: nil
        )

        XCTAssertEqual(modelIQ.primaryModelRow.point.score, 150)
        XCTAssertEqual(modelIQ.primaryModelRow.point.model, "gpt-5.6-sol")
        XCTAssertEqual(CodexRadarPresentationText.compactModelName(modelIQ.primaryModelRow.label), "Sol max")
    }

    func testDecodesCurrentStatusPredictionIQAndQuotaRows() throws {
        let data = Data(Self.sampleJSON.utf8)

        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)

        XCTAssertEqual(snapshot.recommendedAction, "wait")
        XCTAssertEqual(snapshot.window.message, "当前没有开启的速蹬窗口")
        XCTAssertEqual(snapshot.prediction.probability24hPercent, 13)
        XCTAssertEqual(snapshot.prediction.probability48hPercent, 30)
        XCTAssertEqual(snapshot.modelIQ.latest.modelDisplayName, "GPT-5.5 xhigh")
        XCTAssertEqual(snapshot.modelIQ.latest.scoreDisplayText, "IQ 125")
        XCTAssertEqual(snapshot.modelIQ.primaryModelRow.label, "GPT-5.5 xhigh")
        XCTAssertEqual(snapshot.modelIQ.primaryModelRow.point.scoreDisplayText, "IQ 125")
        XCTAssertEqual(snapshot.modelIQ.comparisonRows.map(\.label), [
            "GPT-5.5 xhigh",
            "GPT-5.5 high",
            "GPT-5.5 medium",
            "GPT-5.4 xhigh"
        ])
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.rowsForDisplay.map(\.tier), [
            "Plus",
            "5x Pro",
            "20x Pro"
        ])
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.rowsForDisplay.first?.fiveHourDisplayText, "$13.83")
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.trend.last?.fiveHour20x, 276.66)
        XCTAssertEqual(snapshot.codexEnvironment?.roleCounts["market_motive"], 38)
    }

    func testDecodesPublicSummaryWithoutFullOnlyRadarFields() throws {
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(Self.publicSummaryJSON.utf8))

        XCTAssertEqual(snapshot.recommendedAction, "wait")
        XCTAssertEqual(snapshot.window.message, "当前没有开启的速蹬窗口")
        XCTAssertEqual(snapshot.prediction.probability24hPercent, 17)
        XCTAssertEqual(snapshot.prediction.probability48hPercent, 34)
        XCTAssertNil(snapshot.prediction.expectedWindow)
        XCTAssertEqual(snapshot.prediction.positiveSignals, [])
        XCTAssertEqual(snapshot.prediction.negativeSignals, [])
        XCTAssertEqual(snapshot.recentWindows, [])
        XCTAssertNil(snapshot.codexEnvironment)
        XCTAssertEqual(snapshot.modelIQ.primaryModelRow.label, "GPT-5.5 high")
        XCTAssertEqual(snapshot.modelIQ.primaryModelRow.point.scoreDisplayText, "IQ 100")
        XCTAssertEqual(snapshot.modelIQ.secondaryModelRows.map(\.label), ["GPT-5.5 xhigh"])
        XCTAssertEqual(snapshot.modelIQ.chartSeries.first?.points.count, 1)
    }

    func testDecodesCurrentSevenDayOnlyQuotaSchemaWithoutInventingFiveHourValues() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.publicSummaryJSON.utf8)) as? [String: Any]
        )
        var modelIQ = try XCTUnwrap(root["model_iq"] as? [String: Any])
        modelIQ["quota_radar"] = [
            "date": "2026-07-19",
            "source": "super-account-app-server-measurement",
            "updated_at": "2026-07-19T04:35:09+00:00",
            "basis_date": "2026-07-19",
            "cost_usd": 369.517156,
            "basis_window": "secondary_7d",
            "basis_window_label": "7d",
            "raw_delta": 19,
            "endpoint": "https://api.codexradar.com/api/v1/quota",
            "source_kind": "quota_api",
            "tasks": 78,
            "five_hour_policy": "temporarily_paused_hidden",
            "seven_day_policy": "direct_quota_api",
            "rows": [
                ["tier": "20x Pro", "basis": "distributed radar", "five_h": NSNull(), "seven_d": 1944.83],
                ["tier": "5x Pro", "basis": "estimated", "five_h": NSNull(), "seven_d": 486.21],
                ["tier": "Plus", "basis": "estimated", "five_h": NSNull(), "seven_d": 97.24]
            ],
            "trend": [[
                "date": "2026-07-19",
                "source": "super-account-app-server-measurement",
                "updated_at": "2026-07-19T04:35:09+00:00",
                "five_h_20x": NSNull(),
                "seven_d_20x": 1944.83,
                "five_h_5x": NSNull(),
                "five_h_plus": NSNull(),
                "basis_window": "secondary_7d",
                "basis_window_label": "7d",
                "cost_usd": 369.517156
            ]]
        ]
        root["model_iq"] = modelIQ

        let data = try JSONSerialization.data(withJSONObject: root)
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)
        let quotaRadar = try XCTUnwrap(snapshot.modelIQ.quotaRadar)

        XCTAssertNil(quotaRadar.totalTokens)
        XCTAssertNil(quotaRadar.adjustedDelta)
        XCTAssertNil(quotaRadar.rate)
        XCTAssertEqual(quotaRadar.fiveHourPolicy, "temporarily_paused_hidden")
        XCTAssertEqual(quotaRadar.availableWindows, [.sevenDay])
        XCTAssertEqual(quotaRadar.resolvedWindow(.fiveHour), .sevenDay)
        XCTAssertNil(quotaRadar.rowsForDisplay.first?.fiveH)
        XCTAssertEqual(quotaRadar.rowsForDisplay.first?.fiveHourDisplayText, "--")
        XCTAssertEqual(quotaRadar.rowsForDisplay.first?.sevenDayDisplayText, "$97.24")
        XCTAssertTrue(quotaRadar.chartSeries(for: .fiveHour).isEmpty)
        let sevenDayValues = quotaRadar.chartSeries(for: .sevenDay).compactMap { $0.points.first?.value }
        XCTAssertEqual(sevenDayValues.count, 3)
        XCTAssertEqual(sevenDayValues[0], 97.2415, accuracy: 0.000_001)
        XCTAssertEqual(sevenDayValues[1], 486.2075, accuracy: 0.000_001)
        XCTAssertEqual(sevenDayValues[2], 1944.83, accuracy: 0.000_001)

        for policy in ["cancelled", "removed", "retired"] {
            var variantRoot = root
            var variantModelIQ = modelIQ
            var variantQuota = try XCTUnwrap(variantModelIQ["quota_radar"] as? [String: Any])
            variantQuota["five_hour_policy"] = policy
            variantQuota["rows"] = [[
                "tier": "20x Pro",
                "basis": "distributed radar",
                "five_h": 100,
                "seven_d": 1944.83,
            ]]
            variantModelIQ["quota_radar"] = variantQuota
            variantRoot["model_iq"] = variantModelIQ
            let variantData = try JSONSerialization.data(withJSONObject: variantRoot)
            let variant = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: variantData)
            XCTAssertEqual(variant.modelIQ.quotaRadar?.availableWindows, [.sevenDay])
        }
    }

    func testDecodesFormattingOnlyKeyVariantsAndNumericStrings() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.sampleJSON.utf8)) as? [String: Any]
        )
        root["MONITORED-AT"] = root.removeValue(forKey: "monitored_at")
        root["WINDOW OPEN"] = "false"
        root.removeValue(forKey: "window_open")

        var prediction = try XCTUnwrap(root.removeValue(forKey: "prediction") as? [String: Any])
        prediction["Probability-24-H"] = "0.13"
        prediction.removeValue(forKey: "probability_24h")
        prediction["PROBABILITY 48H"] = "0.30"
        prediction.removeValue(forKey: "probability_48h")
        root["PRE-DICTION"] = prediction

        var modelIQ = try XCTUnwrap(root.removeValue(forKey: "model_iq") as? [String: Any])
        var latest = try XCTUnwrap(modelIQ.removeValue(forKey: "latest") as? [String: Any])
        latest["SCORE"] = "125"
        latest["TOTAL-TOKENS"] = "39090118"
        latest.removeValue(forKey: "total_tokens")
        modelIQ["LATEST"] = latest

        var quotaRadar = try XCTUnwrap(modelIQ.removeValue(forKey: "quota_radar") as? [String: Any])
        var rows = try XCTUnwrap(quotaRadar["rows"] as? [[String: Any]])
        rows[0]["FIVE-H"] = rows[0].removeValue(forKey: "five_h")
        rows[0]["SEVEN D"] = rows[0].removeValue(forKey: "seven_d")
        quotaRadar["ROWS"] = rows
        modelIQ["QUOTA-RADAR"] = quotaRadar
        root["MODEL IQ"] = modelIQ

        let data = try JSONSerialization.data(withJSONObject: ["PAY-LOAD": root])
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)

        XCTAssertEqual(snapshot.monitoredAt, "2026-06-23T08:51:28.710622+08:00")
        XCTAssertEqual(snapshot.windowOpen, false)
        XCTAssertEqual(snapshot.prediction.probability24hPercent, 13)
        XCTAssertEqual(snapshot.prediction.probability48hPercent, 30)
        XCTAssertEqual(snapshot.modelIQ.primaryModelPoint?.scoreDisplayText, "IQ 125")
        XCTAssertEqual(snapshot.modelIQ.latest.totalTokens, 39_090_118)
        XCTAssertNotNil(snapshot.modelIQ.quotaRadar?.rowsForDisplay.first?.sevenD)
    }

    func testOneChangedBlockAndBadArrayElementsDoNotHideHealthyRadarSections() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.sampleJSON.utf8)) as? [String: Any]
        )
        root["prediction"] = ["unexpected_v3": ["value": 1]]
        root["recent_windows"] = [
            "broken",
            ["title": "仍可读取的历史窗口", "status": "closed"]
        ]

        var modelIQ = try XCTUnwrap(root["model_iq"] as? [String: Any])
        modelIQ["latest"] = ["score": ["new_shape": 125]]
        modelIQ["comparisons"] = ["broken": ["latest": "not_an_object"]]
        var quotaRadar = try XCTUnwrap(modelIQ["quota_radar"] as? [String: Any])
        var rows = try XCTUnwrap(quotaRadar["rows"] as? [Any])
        rows.insert(["tier": 123, "five_h": "unknown"], at: 0)
        quotaRadar["rows"] = rows
        modelIQ["quota_radar"] = quotaRadar
        root["model_iq"] = modelIQ

        root["codex_environment"] = [
            "official_updates_24h": "4",
            "official_news": [
                ["title_zh": "仍可读取的资讯", "url": "https://codexradar.com/kept"],
                ["title_zh": 123]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: root)
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)

        XCTAssertEqual(snapshot.window.message, "当前没有开启的速蹬窗口")
        XCTAssertNil(snapshot.prediction.probability24hPercent)
        XCTAssertNil(snapshot.modelIQ.primaryModelPoint)
        XCTAssertEqual(snapshot.modelIQ.primaryModelRow.point.scoreDisplayText, "IQ --")
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.rowsForDisplay.count, 3)
        XCTAssertEqual(snapshot.recentWindows.map(\.title), ["仍可读取的历史窗口"])
        XCTAssertEqual(snapshot.codexEnvironment?.officialUpdates24h, 4)
        XCTAssertEqual(snapshot.codexEnvironment?.officialNews.map(\.titleZh), ["仍可读取的资讯"])
    }

    func testPayloadWithoutAnyUsableRadarBlockStillFailsClosed() throws {
        XCTAssertThrowsError(
            try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(#"{"schema_version":"3"}"#.utf8))
        )
    }

    func testPrimaryModelUsesHighestCurrentComparisonInsteadOfRawLatest() {
        let xhigh = Self.modelIQPoint(score: 87.5, reasoningEffort: "xhigh")
        let high = Self.modelIQPoint(score: 100, reasoningEffort: "high")
        let modelIQ = CodexRadarModelIQ(
            latest: xhigh,
            recentDays: [xhigh],
            comparisons: [
                "gpt_55_high": CodexRadarModelIQComparison(
                    label: "GPT-5.5 high",
                    model: "gpt-5.5",
                    reasoningEffort: "high",
                    latest: high,
                    recentDays: [high]
                )
            ],
            quotaCalibration: nil,
            quotaRadar: nil,
            quotaCheck: nil
        )

        XCTAssertEqual(modelIQ.latest.reasoningEffort, "xhigh")
        XCTAssertEqual(modelIQ.primaryModelRow.label, "GPT-5.5 high")
        XCTAssertEqual(modelIQ.primaryModelRow.point.reasoningEffort, "high")
        XCTAssertEqual(modelIQ.primaryModelRow.point.scoreDisplayText, "IQ 100")
        XCTAssertEqual(modelIQ.secondaryModelRows.map(\.label), ["GPT-5.5 xhigh"])
    }

    func testPrimaryModelUsesLowerCostWhenHighAndXHighScoresTie() {
        let xhigh = Self.modelIQPoint(score: 100, reasoningEffort: "xhigh", costUsd: 37)
        let high = Self.modelIQPoint(score: 100, reasoningEffort: "high", costUsd: 29)
        let modelIQ = CodexRadarModelIQ(
            latest: xhigh,
            recentDays: [xhigh],
            comparisons: [
                "gpt_55_high": CodexRadarModelIQComparison(
                    label: "GPT-5.5 high",
                    model: "gpt-5.5",
                    reasoningEffort: "high",
                    latest: high,
                    recentDays: [high]
                )
            ],
            quotaCalibration: nil,
            quotaRadar: nil,
            quotaCheck: nil
        )

        XCTAssertEqual(modelIQ.primaryModelRow.label, "GPT-5.5 high")
        XCTAssertEqual(modelIQ.primaryModelRow.point.reasoningEffort, "high")
        XCTAssertEqual(modelIQ.secondaryModelRows.map(\.label), ["GPT-5.5 xhigh"])
    }

    func testReaderDecodesPayloadFromInjectedTransport() async throws {
        let reader = LiveCodexRadarReader(
            transport: { _ in
                (Data(Self.sampleJSON.utf8), HTTPURLResponse(
                    url: URL(string: "https://codexradar.com/current.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        let snapshot = try await reader.readRadar()

        XCTAssertEqual(snapshot.schemaVersion, "2.0")
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.basisWindowLabel, "7d")
    }

    func testPublicReaderUsesCurrentJSONWithoutAuthorization() async throws {
        let capture = RadarRequestCapture()
        let reader = LiveCodexRadarReader(
            transport: { request in
                await capture.record(request)
                return (Data(Self.publicSummaryJSON.utf8), HTTPURLResponse(
                    url: request.url ?? URL(string: "https://codexradar.com/current.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        _ = try await reader.readRadar()
        let capturedRequest = await capture.captured()
        let request = try XCTUnwrap(capturedRequest)

        XCTAssertEqual(request.url?.absoluteString, "https://codexradar.com/current.json")
        XCTAssertFalse(
            request.allHTTPHeaderFields?.keys.contains("Authorization") == true,
            "Non-full endpoint should not send Authorization"
        )
    }

    func testDetailReaderUsesFullAPIWithObfuscatedBearerAuthorization() async throws {
        let capture = RadarRequestCapture()
        let reader = LiveCodexRadarDetailReader(
            transport: { request in
                await capture.record(request)
                return (Data(Self.sampleJSON.utf8), HTTPURLResponse(
                    url: request.url ?? URL(string: "https://codexradar.com/api/v1/current")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        _ = try await reader.readRadarDetail()
        let capturedRequest = await capture.captured()
        let request = try XCTUnwrap(capturedRequest)
        let authorization = request.value(forHTTPHeaderField: "Authorization")

        XCTAssertEqual(request.url?.absoluteString, "https://codexradar.com/api/v1/current")
        XCTAssertTrue(authorization?.hasPrefix("Bearer ") == true, "Full detail reader should send a bearer header")
        XCTAssertGreaterThan(authorization?.count ?? 0, "Bearer ".count)
    }

    func testDetailReaderDoesNotAttachAuthorizationToNonFullAPIEndpoint() async throws {
        let capture = RadarRequestCapture()
        let reader = LiveCodexRadarDetailReader(
            endpoint: URL(string: "https://codexradar.com/current.json")!,
            transport: { request in
                await capture.record(request)
                return (Data(Self.publicSummaryJSON.utf8), HTTPURLResponse(
                    url: request.url ?? URL(string: "https://codexradar.com/current.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        _ = try await reader.readRadarDetail()
        let capturedRequest = await capture.captured()
        let request = try XCTUnwrap(capturedRequest)

        XCTAssertEqual(request.url?.absoluteString, "https://codexradar.com/current.json")
        XCTAssertFalse(
            request.allHTTPHeaderFields?.keys.contains("Authorization") == true,
            "Public reader should not send Authorization"
        )
    }

    func testParsesRSSFeedItemsForDetailHistory() throws {
        let items = try CodexRadarFeedParser.parse(Data(Self.sampleRSS.utf8))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.title, "权益记录：Codex 用量限制已重置")
        XCTAssertEqual(items.first?.guid, "codex-speed-window-2026-06-17-codex-close")
        XCTAssertEqual(items.first?.pubDate, "Wed, 17 Jun 2026 21:25:51 GMT")
        XCTAssertTrue(items.first?.description.contains("Codex 用量限制已重置") == true)
        XCTAssertEqual(items.last?.title, "速蹬窗口开启：500 万用户庆祝重置")
    }

    func testModelIQBuildsSelectableMultiModelChartSeries() throws {
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(Self.sampleJSON.utf8))

        let series = snapshot.modelIQ.chartSeries

        XCTAssertEqual(series.map(\.label), [
            "GPT-5.5 xhigh",
            "GPT-5.5 high",
            "GPT-5.5 medium",
            "GPT-5.4 xhigh"
        ])
        XCTAssertEqual(series.first?.points.map(\.xLabel), ["6.22 pm", "6.23"])
        XCTAssertEqual(series.first?.points.map(\.value), [50, 125])
        XCTAssertEqual(series.dropFirst().first?.points.map(\.value), [62.5, 87.5])
    }

    func testShortDateLabelFormatsValidRadarDatesForAnyYearAndFallsBackSafely() {
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2026-06-22-pm"), "6.22 pm")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2026-06-23"), "6.23")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2026-07-01-am"), "7.1 am")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2026-12-03-pm"), "12.3 pm")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2027-01-09-am"), "1.9 am")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2031-11-30"), "11.30")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("not-a-radar-date"), "not-a-radar-date")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2027-02-30"), "2027-02-30")
        XCTAssertEqual(CodexRadarChartPoint.shortDateLabel("2027-07-01-noon"), "2027-07-01-noon")
    }

    func testQuotaRadarBuildsWindowAndTierChartSeries() throws {
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(Self.sampleJSON.utf8))
        let quotaRadar = try XCTUnwrap(snapshot.modelIQ.quotaRadar)

        let fiveHourSeries = quotaRadar.chartSeries(for: .fiveHour)
        let sevenDaySeries = quotaRadar.chartSeries(for: .sevenDay)

        XCTAssertEqual(fiveHourSeries.map(\.label), ["Plus", "5x Pro", "20x Pro"])
        XCTAssertEqual(fiveHourSeries.first?.points.map(\.value), [15.17, 13.83])
        XCTAssertEqual(fiveHourSeries.last?.points.map(\.value), [303.36, 276.66])
        XCTAssertEqual(sevenDaySeries.map(\.label), ["Plus", "5x Pro", "20x Pro"])
        XCTAssertEqual(sevenDaySeries.first?.points.map(\.value).first ?? 0, 91.008, accuracy: 0.001)
        XCTAssertEqual(sevenDaySeries.dropFirst().first?.points.map(\.value).last ?? 0, 414.9825, accuracy: 0.001)
        XCTAssertEqual(sevenDaySeries.last?.points.map(\.value), [1820.16, 1659.93])
    }

    private static func modelIQPoint(
        score: Double,
        reasoningEffort: String,
        costUsd: Double = 10,
        model: String = "gpt-5.5"
    ) -> CodexRadarModelIQPoint {
        CodexRadarModelIQPoint(
            date: "2026-06-24-am",
            score: score,
            status: score >= 100 ? "green" : "yellow",
            passed: Int(score / 12.5),
            tasks: 12,
            invalid: 0,
            totalTokens: 1_000_000,
            inputTokens: 900_000,
            cachedInputTokens: 800_000,
            outputTokens: 100_000,
            wallSeconds: 1200,
            wallTimeHuman: "20分钟",
            model: model,
            reasoningEffort: reasoningEffort,
            validTasks: 12,
            costUsd: costUsd
        )
    }

    static let sampleJSON = """
    {
      "schema_version": "2.0",
      "service": "codex-reset-radar",
      "monitored_at": "2026-06-23T08:51:28.710622+08:00",
      "timezone": "Asia/Shanghai",
      "window_open": false,
      "status": "none",
      "recommended_action": "wait",
      "window": {
        "open": false,
        "status": "none",
        "action": "wait",
        "message": "当前没有开启的速蹬窗口",
        "title": "Codex 用量限制重置",
        "scope": "Codex 用户",
        "opened_at": null,
        "closed_at": "2026-06-18T08:10:10+08:00",
        "source_url": "https://x.com/thsottiaux/status/2067399435009622521"
      },
      "prediction": {
        "level": "medium_low",
        "probability_24h": 0.13,
        "probability_48h": 0.3,
        "expected_window": "未来 24-48 小时",
        "summary": "没有官方窗口或长时未补偿事故，不能给高概率。",
        "summary_en": "No official window or long uncompensated incident is present.",
        "positive_signals": ["Tibo/Sam/OpenAI 在过去 24 小时集中推广 Codex"],
        "negative_signals": ["official_window_review 已确认没有 Tibo/Sam/OpenAI 官方 reset 窗口"],
        "updated_at": "2026-06-23T08:51:28.347260+08:00"
      },
      "tibo_presence": {
        "schema_version": "1.0",
        "mode": "inferred",
        "timezone": "Europe/Paris",
        "location_label_zh": "法国 / CET",
        "location_label_en": "France / CET",
        "probability": 0.9,
        "confidence": "high",
        "evidence_summary_zh": "公开发帖称自己在法国。",
        "evidence_summary_en": "Public country-level post.",
        "source_urls": ["https://x.com/thsottiaux/status/2067064381855187231"],
        "should_display": true,
        "safety_note_zh": "仅基于公开发帖做国家/时区级推测。",
        "safety_note_en": "Coarse public context only.",
        "updated_at": "2026-06-23T00:51:42.550781Z",
        "observed_at": "2026-06-22T23:55:37Z",
        "stale_at": "2026-06-24T00:55:37Z",
        "observations_considered": 40
      },
      "recent_windows": [],
      "links": {
        "html": "https://codexradar.com/",
        "rss": "https://codexradar.com/feed.xml"
      },
      "model_iq": {
        "latest": {
          "date": "2026-06-23",
          "score": 125.0,
          "status": "green",
          "passed": 10,
          "tasks": 12,
          "invalid": 0,
          "total_tokens": 41602755,
          "input_tokens": 41238081,
          "cached_input_tokens": 39315328,
          "output_tokens": 364674,
          "wall_seconds": 2757,
          "wall_time_human": "46分钟",
          "model": "gpt-5.5",
          "reasoning_effort": "xhigh",
          "valid_tasks": 12,
          "cost_usd": 40.211649
        },
        "recent_days": [
          {
            "date": "2026-06-22-pm",
            "score": 50.0,
            "status": "red",
            "passed": 4,
            "tasks": 12,
            "invalid": 0,
            "total_tokens": 44515136,
            "input_tokens": 44137718,
            "cached_input_tokens": 41759360,
            "output_tokens": 377418,
            "wall_seconds": 3261,
            "wall_time_human": "54分钟"
          },
          {
            "date": "2026-06-23",
            "score": 125.0,
            "status": "green",
            "passed": 10,
            "tasks": 12,
            "invalid": 0,
            "total_tokens": 41602755,
            "input_tokens": 41238081,
            "cached_input_tokens": 39315328,
            "output_tokens": 364674,
            "wall_seconds": 2757,
            "wall_time_human": "46分钟"
          }
        ],
        "comparisons": {
          "gpt_55_high": {
            "label": "GPT-5.5 high",
            "model": "gpt-5.5",
            "reasoning_effort": "high",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 30939960,
              "input_tokens": 30702185,
              "cached_input_tokens": 28715776,
              "output_tokens": 237775,
              "wall_seconds": 3049,
              "wall_time_human": "51分钟",
              "model": "gpt-5.5",
              "reasoning_effort": "high",
              "valid_tasks": 12,
              "cost_usd": 31.423183
            },
            "recent_days": [
              {
                "date": "2026-06-22-pm",
                "score": 62.5,
                "status": "red",
                "passed": 5,
                "tasks": 12,
                "invalid": 0,
                "total_tokens": 30279872,
                "input_tokens": 30046951,
                "cached_input_tokens": 28154624,
                "output_tokens": 232921,
                "wall_seconds": 3757,
                "wall_time_human": "1小时3分"
              },
              {
                "date": "2026-06-23",
                "score": 87.5,
                "status": "yellow",
                "passed": 7,
                "tasks": 12,
                "invalid": 0,
                "total_tokens": 30939960,
                "input_tokens": 30702185,
                "cached_input_tokens": 28715776,
                "output_tokens": 237775,
                "wall_seconds": 3049,
                "wall_time_human": "51分钟"
              }
            ]
          },
          "gpt_55_medium": {
            "label": "GPT-5.5 medium",
            "model": "gpt-5.5",
            "reasoning_effort": "medium",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 21077844,
              "input_tokens": 20910298,
              "cached_input_tokens": 19402496,
              "output_tokens": 167546,
              "wall_seconds": 1252,
              "wall_time_human": "21分钟",
              "model": "gpt-5.5",
              "reasoning_effort": "medium",
              "valid_tasks": 12,
              "cost_usd": 22.266638
            },
            "recent_days": []
          },
          "gpt_54_xhigh": {
            "label": "GPT-5.4 xhigh",
            "model": "gpt-5.4",
            "reasoning_effort": "xhigh",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 42712526,
              "input_tokens": 42238309,
              "cached_input_tokens": 40140288,
              "output_tokens": 474217,
              "wall_seconds": 3836,
              "wall_time_human": "1小时4分",
              "model": "gpt-5.4",
              "reasoning_effort": "xhigh",
              "valid_tasks": 12,
              "cost_usd": 22.393379
            },
            "recent_days": []
          }
        },
        "quota_calibration": {
          "schema_version": "1.0",
          "date": "2026-06-23",
          "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
          "status": "valid",
          "primary_window": "primary_5h",
          "global_concurrency": 16,
          "checked_at_before": "2026-06-23T05:30:25Z",
          "checked_at_after": "2026-06-23T06:34:28Z",
          "tasks": 48,
          "valid_tasks": 48,
          "cost_usd": 116.194986,
          "total_tokens": 136899968,
          "windows": {}
        },
        "quota_radar": {
          "date": "2026-06-23",
          "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
          "updated_at": "2026-06-23T06:34:28Z",
          "basis_date": "2026-06-23",
          "cost_usd": 116.194986,
          "total_tokens": 136899968,
          "basis_window": "secondary_7d",
          "basis_window_label": "7d",
          "adjusted_delta": 7,
          "raw_delta": 7,
          "offset": 0,
          "rate": 16.5993,
          "rows": [
            {
              "tier": "20x Pro",
              "basis": "measured 7d",
              "five_h": 276.66,
              "seven_d": 1659.93
            },
            {
              "tier": "5x Pro",
              "basis": "model /4",
              "five_h": 69.17,
              "seven_d": 414.98
            },
            {
              "tier": "Plus",
              "basis": "model /20",
              "five_h": 13.83,
              "seven_d": 83.0
            }
          ],
          "trend": [
            {
              "date": "2026-06-22",
              "source": "model-iq-deepswe-12-v1-4configs-pool16-20260622",
              "updated_at": "2026-06-22T01:55:40Z",
              "five_h_20x": 303.36,
              "seven_d_20x": 1820.16,
              "five_h_5x": 75.84,
              "five_h_plus": 15.17,
              "basis_window": "primary_5h",
              "basis_window_label": "5h",
              "rate": 3.0336,
              "raw_delta": 39,
              "adjusted_delta": 38,
              "offset": 1,
              "cost_usd": 115.278007,
              "total_tokens": 133628889
            },
            {
              "date": "2026-06-23",
              "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
              "updated_at": "2026-06-23T06:34:28Z",
              "five_h_20x": 276.66,
              "seven_d_20x": 1659.93,
              "five_h_5x": 69.17,
              "five_h_plus": 13.83,
              "basis_window": "secondary_7d",
              "basis_window_label": "7d",
              "rate": 16.5993,
              "raw_delta": 7,
              "adjusted_delta": 7,
              "offset": 0,
              "cost_usd": 116.194986,
              "total_tokens": 136899968
            }
          ]
        },
        "quota_check": {
          "schema_version": "1.0",
          "date": "2026-06-23",
          "source": "manual_quota_check",
          "status": "failed",
          "checked_at": "2026-06-23T05:29:31Z",
          "plan_type": null,
          "rate_limit_reset_credits_available_count": null,
          "limit_reached": null,
          "allowed": null,
          "windows": {}
        }
      },
      "codex_environment": {
        "schema_version": "1.0",
        "type": "codex_environment",
        "updated_at": "2026-06-23T08:51:28.347260+08:00",
        "status_incidents_24h": 0,
        "official_updates_24h": 12,
        "community_mentions_24h": 48,
        "issue_or_limit_anomalies_24h": 10,
        "complaint_pressure": "medium",
        "reset_card": {
          "probability_24h": 0.13,
          "probability_48h": 0.3,
          "level": "medium_low",
          "status": "prediction_only",
          "note": "Email and RSS should be reserved for confirmed official card grants or benefit events."
        },
        "official_news": [],
        "status_incidents": [],
        "complaint_examples": [],
        "role_counts": {
          "market_motive": 38,
          "issue_or_limit_anomaly": 10
        }
      }
    }
    """

    static let publicSummaryJSON = """
    {
      "schema_version": "2.0",
      "service": "codex-reset-radar",
      "monitored_at": "2026-06-24T04:52:00.084111+08:00",
      "timezone": "Asia/Shanghai",
      "window_open": false,
      "status": "none",
      "recommended_action": "wait",
      "window": {
        "open": false,
        "status": "none",
        "action": "wait",
        "message": "当前没有开启的速蹬窗口",
        "title": "Codex 用量限制重置",
        "scope": "Codex 用户",
        "opened_at": null,
        "closed_at": null,
        "source_url": null
      },
      "prediction": {
        "level": "medium",
        "probability_24h": 0.17,
        "probability_48h": 0.34,
        "summary": "公开摘要只保留基础预测字段。",
        "summary_en": "Public summary keeps basic prediction fields.",
        "updated_at": "2026-06-24T04:52:00.084111+08:00"
      },
      "links": {
        "html": "https://codexradar.com/",
        "rss": "https://codexradar.com/feed.xml"
      },
      "model_iq": {
        "latest": {
          "date": "2026-06-24",
          "score": 87.5,
          "status": "yellow",
          "passed": 7,
          "tasks": 12,
          "invalid": 0,
          "total_tokens": 34000000,
          "input_tokens": 32000000,
          "cached_input_tokens": 30000000,
          "output_tokens": 400000,
          "wall_seconds": 1380,
          "wall_time_human": "23分钟",
          "model": "gpt-5.5",
          "reasoning_effort": "xhigh",
          "valid_tasks": 12,
          "cost_usd": 37.26
        },
        "comparisons": {
          "gpt_55_high": {
            "label": "GPT-5.5 high",
            "model": "gpt-5.5",
            "reasoning_effort": "high",
            "latest": {
              "date": "2026-06-24",
              "score": 100,
              "status": "green",
              "passed": 8,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 27820000,
              "input_tokens": 26000000,
              "cached_input_tokens": 24000000,
              "output_tokens": 320000,
              "wall_seconds": 1560,
              "wall_time_human": "26分钟",
              "model": "gpt-5.5",
              "reasoning_effort": "high",
              "valid_tasks": 12,
              "cost_usd": 29.01
            }
          }
        }
      }
    }
    """

    private static let sampleRSS = """
    <?xml version='1.0' encoding='utf-8'?>
    <rss version="2.0">
      <channel>
        <title>Codex 雷达</title>
        <link>https://codexradar.com/</link>
        <description>只发布 Codex 速蹬窗口开启和关闭提醒。</description>
        <language>zh-CN</language>
        <ttl>10</ttl>
        <item>
          <title>权益记录：Codex 用量限制已重置</title>
          <link>https://codexradar.com/#codex-speed-window-2026-06-17-codex</link>
          <guid isPermaLink="false">codex-speed-window-2026-06-17-codex-close</guid>
          <pubDate>Wed, 17 Jun 2026 21:25:51 GMT</pubDate>
          <description>Codex 用量限制已重置。确认依据：用户确认已到账。</description>
        </item>
        <item>
          <title>速蹬窗口开启：500 万用户庆祝重置</title>
          <link>https://codexradar.com/#codex-speed-window-2026-05-31-500</link>
          <guid isPermaLink="false">codex-speed-window-2026-05-31-500-open</guid>
          <pubDate>Sun, 31 May 2026 05:59:10 GMT</pubDate>
          <description>发现有效重置预告，速蹬窗口开启。</description>
        </item>
      </channel>
    </rss>
    """
}

private actor RadarRequestCapture {
    private var capturedRequest: URLRequest?

    func captured() -> URLRequest? {
        capturedRequest
    }

    func record(_ request: URLRequest) {
        capturedRequest = request
    }
}
