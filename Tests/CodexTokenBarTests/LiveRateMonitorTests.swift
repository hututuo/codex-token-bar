import XCTest
@testable import CodexTokenBar

final class LiveRateMonitorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testLogRowsFilterThreadIDWithQuotesUsingBindings() throws {
        let databaseURL = try makeDatabaseURL()
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.execute("""
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY,
            thread_id TEXT,
            ts INTEGER,
            ts_nanos INTEGER,
            target TEXT,
            feedback_log_body TEXT
        );
        """)

        let quotedThreadID = "thread-' OR 1=1 --"
        try insertLog(driver: driver, id: 1, threadID: quotedThreadID, body: "websocket event: first")
        try insertLog(driver: driver, id: 2, threadID: quotedThreadID, body: "websocket event: second")
        try insertLog(driver: driver, id: 99, threadID: "other-thread", body: "websocket event: other")

        let maxID = try LiveRateMonitor.testMaxLogID(logsDB: databaseURL.path, threadID: quotedThreadID)
        let rows = try LiveRateMonitor.testLogRows(logsDB: databaseURL.path, threadID: quotedThreadID, afterID: 0)

        XCTAssertEqual(maxID, 2)
        XCTAssertEqual(rows.map(\.id), [1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.threadID == quotedThreadID })
    }

    func testRecentFingerprintSetKeepsOnlyNewestValues() {
        var fingerprints = RecentFingerprintSet(limit: 3)

        XCTAssertTrue(fingerprints.insertIfNew("a"))
        XCTAssertTrue(fingerprints.insertIfNew("b"))
        XCTAssertTrue(fingerprints.insertIfNew("c"))
        XCTAssertFalse(fingerprints.insertIfNew("b"))

        XCTAssertTrue(fingerprints.insertIfNew("d"))

        XCTAssertEqual(fingerprints.count, 3)
        XCTAssertFalse(fingerprints.contains("a"))
        XCTAssertTrue(fingerprints.contains("b"))
        XCTAssertTrue(fingerprints.contains("c"))
        XCTAssertTrue(fingerprints.contains("d"))
    }

    func testPollReadPlanReadsStreamAndRolloutOnLogChange() {
        let plan = LiveRatePollReadPlan(
            now: 100,
            hasLogChangeSignal: true,
            fastDisplayWindowActive: false,
            activeRollingWindowPresent: false,
            lastFallbackPollAt: 99.9,
            lastRolloutReadAt: 99.9,
            idleFallbackPollInterval: 2,
            rolloutFallbackPollInterval: 1
        )

        XCTAssertTrue(plan.readStreamRows)
        XCTAssertTrue(plan.readRolloutUpdates)
        XCTAssertTrue(plan.readsAnyDataSource)
        XCTAssertFalse(plan.recordIdleFallbackPollAt)
    }

    func testPollReadPlanReadsRolloutWhenSqliteStreamIsNotDue() {
        let plan = LiveRatePollReadPlan(
            now: 100,
            hasLogChangeSignal: false,
            fastDisplayWindowActive: false,
            activeRollingWindowPresent: false,
            lastFallbackPollAt: 99,
            lastRolloutReadAt: 98.9,
            idleFallbackPollInterval: 2,
            rolloutFallbackPollInterval: 1
        )

        XCTAssertFalse(plan.readStreamRows)
        XCTAssertTrue(plan.readRolloutUpdates)
        XCTAssertTrue(plan.readsAnyDataSource)
        XCTAssertFalse(plan.recordIdleFallbackPollAt)
    }

    func testPollReadPlanKeepsFastDisplayWindowDisplayOnly() {
        let plan = LiveRatePollReadPlan(
            now: 100,
            hasLogChangeSignal: false,
            fastDisplayWindowActive: true,
            activeRollingWindowPresent: true,
            lastFallbackPollAt: 99.5,
            lastRolloutReadAt: 99.5,
            idleFallbackPollInterval: 2,
            rolloutFallbackPollInterval: 1
        )

        XCTAssertFalse(plan.readStreamRows)
        XCTAssertFalse(plan.readRolloutUpdates)
        XCTAssertFalse(plan.readsAnyDataSource)
        XCTAssertTrue(plan.displayOnlyFastPollActive)
    }

    func testPollReadPlanThrottlesInactiveReadsUntilFallbackIntervals() {
        let throttled = LiveRatePollReadPlan(
            now: 100,
            hasLogChangeSignal: false,
            fastDisplayWindowActive: false,
            activeRollingWindowPresent: false,
            lastFallbackPollAt: 99,
            lastRolloutReadAt: 99.5,
            idleFallbackPollInterval: 2,
            rolloutFallbackPollInterval: 1
        )

        XCTAssertFalse(throttled.readStreamRows)
        XCTAssertFalse(throttled.readRolloutUpdates)
        XCTAssertFalse(throttled.readsAnyDataSource)
        XCTAssertFalse(throttled.recordIdleFallbackPollAt)

        let fallbackDue = LiveRatePollReadPlan(
            now: 101,
            hasLogChangeSignal: false,
            fastDisplayWindowActive: false,
            activeRollingWindowPresent: false,
            lastFallbackPollAt: 99,
            lastRolloutReadAt: 99.5,
            idleFallbackPollInterval: 2,
            rolloutFallbackPollInterval: 1
        )

        XCTAssertTrue(fallbackDue.readStreamRows)
        XCTAssertTrue(fallbackDue.readRolloutUpdates)
        XCTAssertTrue(fallbackDue.recordIdleFallbackPollAt)
    }

    func testLiveRateLogReaderReturnsOnlyUsableStreamDeltaRowsAndAttribution() throws {
        let databaseURL = try makeDatabaseURL()
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.execute("""
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY,
            thread_id TEXT,
            ts INTEGER,
            ts_nanos INTEGER,
            target TEXT,
            feedback_log_body TEXT
        );
        """)
        try insertLog(
            driver: driver,
            id: 1,
            target: "codex_api::sse::responses",
            body: #"SSE event: {"type":"response.created","response":{"id":"resp-large","status":"in_progress"}}"#
        )
        try insertLog(
            driver: driver,
            id: 2,
            target: "codex_api::sse::responses",
            body: #"SSE event: {"type":"response.output_text.delta","delta":"普通输出","item_id":"msg-1","sequence_number":1}"#
        )
        try insertLog(
            driver: driver,
            id: 3,
            target: "codex_api::sse::responses",
            body: #"SSE event: {"type":"response.function_call_arguments.delta","delta":"{\"cmd\":\"date\"}","item_id":"fc-1","sequence_number":2}"#
        )
        try insertLog(
            driver: driver,
            id: 4,
            target: "codex_api::sse::responses",
            body: #"SSE event: {"type":"response.output_item.added","item":{"id":"fc-2","type":"function_call","name":"apply_patch","call_id":"call-1"},"sequence_number":3}"#
        )
        try insertLog(
            driver: driver,
            id: 5,
            target: "codex_api::sse::responses",
            body: #"SSE event: {"type":"response.completed","response":{"id":"resp-large","output":[{"type":"message","content":[{"type":"output_text","text":"large"}]}]}}"#
        )
        try insertLog(
            driver: driver,
            id: 6,
            target: "log",
            body: #"Received message {"type":"response.output_text.delta","delta":"桥接输出","item_id":"msg-2","sequence_number":4}"#
        )
        try insertLog(
            driver: driver,
            id: 7,
            target: "codex_api::endpoint::responses_websocket",
            body: #"websocket event: {"type":"response.custom_tool_call_input.delta","delta":"patch","item_id":"fc-3","sequence_number":5}"#
        )

        let rows = try LiveRateLogDatabaseReader(path: databaseURL.path).globalLogRows(afterID: 0)

        XCTAssertEqual(rows.map(\.id), [2, 3, 4, 6, 7])
    }

    func testStreamParserKeepsToolArgumentDeltasOutOfVisibleTextButInLiveRate() throws {
        let row = LiveRateMonitor.LogRow(
            id: 1,
            threadID: nil,
            ts: 1_000,
            tsNanos: 0,
            target: "codex_api::sse::responses",
            feedbackLogBody: #"SSE event: {"type":"response.function_call_arguments.delta","delta":"{\"cmd\":\"date\"}","item_id":"fc-1","sequence_number":1}"#
        )

        let streamEvent = try XCTUnwrap(LiveRateMonitor.streamEvent(from: row))
        let events = LiveRateMonitor.metricEvents(from: streamEvent, row: row, toolNames: [:])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.category, .toolArguments)
        XCTAssertTrue(try XCTUnwrap(events.first?.category).contributesToLiveRate)
    }

    func testStreamParserKeepsOutputTextDeltasAsVisibleText() throws {
        let row = LiveRateMonitor.LogRow(
            id: 1,
            threadID: nil,
            ts: 1_000,
            tsNanos: 0,
            target: "codex_api::sse::responses",
            feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"普通输出","item_id":"msg-1","sequence_number":1}"#
        )

        let streamEvent = try XCTUnwrap(LiveRateMonitor.streamEvent(from: row))
        let events = LiveRateMonitor.metricEvents(from: streamEvent, row: row, toolNames: [:])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertTrue(try XCTUnwrap(events.first?.category).contributesToLiveRate)
    }

    func testStreamParserReadsBridgedLogOutputTextDeltas() throws {
        let row = LiveRateMonitor.LogRow(
            id: 1,
            threadID: nil,
            ts: 1_000,
            tsNanos: 0,
            target: "log",
            feedbackLogBody: #"Received message {"type":"response.output_text.delta","delta":"小段普通输出","item_id":"msg-1","sequence_number":12}"#
        )

        let streamEvent = try XCTUnwrap(LiveRateMonitor.streamEvent(from: row))
        let events = LiveRateMonitor.metricEvents(from: streamEvent, row: row, toolNames: [:])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.source, .bridgedLog)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertEqual(events.first?.text, "小段普通输出")
        XCTAssertTrue(try XCTUnwrap(events.first?.category).contributesToLiveRate)
    }

    func testStreamParserReadsBridgedLogToolArgumentsForLiveRate() throws {
        let row = LiveRateMonitor.LogRow(
            id: 1,
            threadID: nil,
            ts: 1_000,
            tsNanos: 0,
            target: "log",
            feedbackLogBody: #"Received message {"type":"response.function_call_arguments.delta","delta":"{\"cmd\":\"date\"}","item_id":"fc-1","sequence_number":12}"#
        )

        let streamEvent = try XCTUnwrap(LiveRateMonitor.streamEvent(from: row))
        let events = LiveRateMonitor.metricEvents(from: streamEvent, row: row, toolNames: [:])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.source, .bridgedLog)
        XCTAssertEqual(events.first?.category, .toolArguments)
        XCTAssertEqual(events.first?.text, #"{"cmd":"date"}"#)
        XCTAssertTrue(try XCTUnwrap(events.first?.category).contributesToLiveRate)
    }

    func testLiveRateInstrumentExplainsThatRateIncludesToolInputStreams() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("含输出与工具输入流"))
        XCTAssertTrue(source.contains("部分流式可能延迟"))
        XCTAssertTrue(source.contains("部分 Codex 流式事件可能不会实时落入本地日志"))
    }

    func testLiveRateInstrumentExplainsEstimatedRateAndExposesDisableToggle() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let viewSource = try String(contentsOf: viewSourceURL, encoding: .utf8)
        let dashboardSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let dashboardSource = try String(contentsOf: dashboardSourceURL, encoding: .utf8)
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)
        let instrumentRange = try XCTUnwrap(viewSource.range(of: "struct LiveRateInstrument: View"))
        let controlsRange = try XCTUnwrap(viewSource.range(of: "struct LiveRateControls: View"))
        let scaleSliderRange = try XCTUnwrap(
            viewSource.range(
                of: "private struct RateFullScaleSlider: View",
                range: instrumentRange.upperBound..<controlsRange.lowerBound
            )
        )
        let instrumentSource = String(viewSource[instrumentRange.lowerBound..<scaleSliderRange.lowerBound])
        let controlsSource = String(viewSource[controlsRange.lowerBound..<viewSource.endIndex])

        XCTAssertTrue(viewSource.contains("官方为避免高频日志写入损耗硬盘"))
        XCTAssertTrue(viewSource.contains("砍掉了很多流式输出日志"))
        XCTAssertTrue(viewSource.contains("大部分速率只是估算"))
        XCTAssertTrue(viewSource.contains("只用于判断 Codex 是否正在干活"))
        XCTAssertTrue(viewSource.contains("不代表真实速率"))
        XCTAssertTrue(instrumentSource.contains("isMonitoringEnabled"))
        XCTAssertTrue(instrumentSource.contains("LiveRatePowerToggle"))
        XCTAssertTrue(instrumentSource.contains("实时速率已关闭"))
        XCTAssertTrue(instrumentSource.contains("LiveRateDisabledOverlay"))
        XCTAssertTrue(viewSource.contains("@Binding var floatingPanelShowRateAndBar"))
        XCTAssertTrue(viewSource.contains("floatingPanelShowRateAndBar = enabled"))
        XCTAssertTrue(viewSource.contains("floatingPanelShowRateAndBar: $floatingPanelShowRateAndBar"))
        XCTAssertFalse(controlsSource.contains(#"title: "实时速率""#))
        XCTAssertTrue(dashboardSource.contains(#"@AppStorage("liveRateMonitoringEnabled")"#))
        XCTAssertTrue(dashboardSource.contains(#"@AppStorage(FloatingPanelContentVisibility.rateAndBarKey)"#))
        XCTAssertTrue(viewSource.contains("syncMonitoringEnabled(liveRateMonitoringEnabled)"))
        XCTAssertTrue(viewSource.contains("monitor.setMonitoringEnabled(enabled)"))
        XCTAssertTrue(monitorSource.contains("func setMonitoringEnabled(_ enabled: Bool)"))
        XCTAssertTrue(monitorSource.contains("实时速率已关闭"))
    }

    func testLiveRateBarUsesLayerBackedFillInsteadOfSwiftUIShapeRepaint() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sharedFillSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/SmoothRateFillBar.swift")
        let sharedFillSource = try String(contentsOf: sharedFillSourceURL, encoding: .utf8)

        XCTAssertTrue(sharedFillSource.contains("import AppKit"))
        XCTAssertTrue(sharedFillSource.contains("struct SmoothRateFillBar: NSViewRepresentable"))
        XCTAssertTrue(sharedFillSource.contains("CAGradientLayer"))
        XCTAssertTrue(sharedFillSource.contains("CABasicAnimation"))
        XCTAssertTrue(sharedFillSource.contains("contentsScale"))
        XCTAssertTrue(sharedFillSource.contains("cornerRadius"))
        XCTAssertTrue(sharedFillSource.contains("rounded(.toNearestOrAwayFromZero)"))
        XCTAssertFalse(sharedFillSource.contains("SmoothRateFillShape"))
        XCTAssertFalse(sharedFillSource.contains("path.addRoundedRect"))
        XCTAssertFalse(sharedFillSource.contains("struct SmoothRateFillBar: View, Animatable"))
        XCTAssertTrue(source.contains("SmoothRateFillBar("))
        XCTAssertFalse(source.contains(".animation(.linear(duration: 0.32), value: fillFraction)"))
        XCTAssertFalse(source.contains(".animation(.linear(duration: 0.18), value: fillScale)"))
        XCTAssertFalse(source.contains(".frame(width: max(8, proxy.size.width * fillFraction))"))
        XCTAssertFalse(source.contains("TimelineView"))
        XCTAssertFalse(source.contains("Timer.publish"))
    }

    func testFloatingRateBarUsesSharedSmoothFillWithoutWidthRelayout() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/TokenDisplaySurfaceComponents.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rateBarRange = try XCTUnwrap(source.range(of: "struct TokenDisplayRateBar: View"))
        let nextStructRange = try XCTUnwrap(
            source.range(
                of: "struct TokenDisplayMetric: View",
                range: rateBarRange.upperBound..<source.endIndex
            )
        )
        let rateBarSource = String(source[rateBarRange.lowerBound..<nextStructRange.lowerBound])

        XCTAssertTrue(rateBarSource.contains("SmoothRateFillBar("))
        XCTAssertFalse(rateBarSource.contains(".animation(.linear(duration: 0.32), value: fillFraction)"))
        XCTAssertTrue(rateBarSource.contains(#"accessibilityLabel("实时速率条")"#))
        XCTAssertFalse(rateBarSource.contains("let fillWidth"))
        XCTAssertFalse(rateBarSource.contains(".frame(width: fillWidth)"))
        XCTAssertFalse(rateBarSource.contains("TimelineView"))
        XCTAssertFalse(rateBarSource.contains("Timer.publish"))
    }

    func testLiveRateNumberUsesAnimatableTextWithoutHighFrequencyTimer() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("struct SmoothRateValueText: View, Animatable"))
        XCTAssertFalse(source.contains("SmoothRateValueText(value: snapshot.rollingTokensPerSecond)"))
        XCTAssertFalse(source.contains(".animation(.linear(duration: 0.2), value: snapshot.rollingTokensPerSecond)"))
        XCTAssertTrue(source.contains("Text(snapshot.rollingTokensPerSecondText)"))
        XCTAssertFalse(source.contains(#"Text(String(format: "%.1f", snapshot.rollingTokensPerSecond))"#))
        XCTAssertFalse(source.contains("TimelineView"))
        XCTAssertFalse(source.contains("Timer.publish"))
    }

    func testLiveRateSnapshotFormatsAllFinitePositiveRatesWithOneDecimal() {
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(0), "0.0")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(-1), "0.0")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(.infinity), "0.0")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(9.64), "9.6")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(40.4), "40.4")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(40.6), "40.6")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(80), "80.0")
    }

    func testSmoothedDisplayRateDampsNearbyRawRateBounce() {
        var smoothed = 40.0
        let rawRates = [42.0, 40.0, 42.0, 40.0]
        let displayedRates = rawRates.map { rawRate in
            smoothed = LiveRateMonitor.smoothedDisplayRate(previous: smoothed, raw: rawRate, hasRecentActivity: true)
            return smoothed
        }

        XCTAssertGreaterThan(displayedRates[0], 40.0)
        XCTAssertLessThan(displayedRates[0], 42.0)
        XCTAssertGreaterThan(displayedRates[1], 40.0)
        XCTAssertLessThan(displayedRates[1], displayedRates[0])
        XCTAssertLessThan(displayedRates[2] - displayedRates[1], 2.0)
        XCTAssertLessThan(displayedRates[3] - 40.0, 1.0)
    }

    func testSmoothedDisplayRateRisesQuicklyAndClearsWhenInactive() {
        let firstActive = LiveRateMonitor.smoothedDisplayRate(previous: 0, raw: 40, hasRecentActivity: true)
        let secondActive = LiveRateMonitor.smoothedDisplayRate(previous: firstActive, raw: 40, hasRecentActivity: true)
        let inactive = LiveRateMonitor.smoothedDisplayRate(previous: secondActive, raw: 0, hasRecentActivity: false)

        XCTAssertEqual(firstActive, 11.2, accuracy: 0.001)
        XCTAssertGreaterThan(secondActive, firstActive)
        XCTAssertEqual(inactive, 0, accuracy: 0.001)
    }

    func testDisplayRateCapsSelectedSessionBeforeCombiningTotalSessions() {
        XCTAssertEqual(LiveRateMonitor.displayRawRate(220, scope: .selectedSession), 80, accuracy: 0.001)
        XCTAssertEqual(LiveRateMonitor.displayRawRate(220, scope: .allSessions), 220, accuracy: 0.001)
        XCTAssertEqual(LiveRateMonitor.combinedAllSessionsDisplayRate([220]), 80, accuracy: 0.001)
        XCTAssertEqual(LiveRateMonitor.combinedAllSessionsDisplayRate([220, 90, 60]), 220, accuracy: 0.001)
    }

    @MainActor
    func testPollBatchCountsDistinctStreamAndRolloutVisibleOutput() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-1")
        let streamRow = LiveRateMonitor.LogRow(
            id: 1,
            threadID: "thread-1",
            ts: 1_000,
            tsNanos: 0,
            target: "codex_api::sse::responses",
            feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"stream visible","item_id":"msg-stream","sequence_number":1}"#
        )
        let rolloutEvent = RolloutMetricEvent(
            timestamp: 1_000.1,
            key: "msg-rollout",
            category: .visibleText,
            text: "rollout visible"
        )

        monitor.testProcessPollInputs(
            streamRows: [streamRow],
            rolloutReads: [LiveRateMonitor.RolloutRead(threadID: "thread-1", path: "/tmp/rollout.jsonl", newOffset: 1, events: [rolloutEvent])],
            now: 1_000.2
        )

        let expected = monitor.estimateTokenCount("stream visible", category: .visibleText)
            + monitor.estimateTokenCount("rollout visible", category: .visibleText)
        XCTAssertEqual(monitor.snapshot.breakdown.visibleText, expected)
        XCTAssertGreaterThan(monitor.snapshot.rollingTokensPerSecond, 0)
    }

    @MainActor
    func testPollBatchDeduplicatesSameVisibleOutputAcrossStreamAndRollout() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-1")
        let streamRow = LiveRateMonitor.LogRow(
            id: 1,
            threadID: "thread-1",
            ts: 1_000,
            tsNanos: 0,
            target: "codex_api::sse::responses",
            feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"same visible","item_id":"msg-1","sequence_number":1}"#
        )
        let duplicateRollout = RolloutMetricEvent(
            timestamp: 1_000.1,
            key: "msg-1",
            category: .visibleText,
            text: "same visible"
        )

        monitor.testProcessPollInputs(
            streamRows: [streamRow],
            rolloutReads: [LiveRateMonitor.RolloutRead(threadID: "thread-1", path: "/tmp/rollout.jsonl", newOffset: 1, events: [duplicateRollout])],
            now: 1_000.2
        )

        XCTAssertEqual(
            monitor.snapshot.breakdown.visibleText,
            monitor.estimateTokenCount("same visible", category: .visibleText)
        )
    }

    @MainActor
    func testDataSourceSwitchClearsSourceLocalLiveRateState() throws {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        let sourceA = try makeCodexDataSource(named: "source-a")
        let sourceB = try makeCodexDataSource(named: "source-b")
        monitor.setDataSource(sourceA)
        monitor.testPrepareForLiveRateProcessing(
            selectedThreadID: "thread-a",
            threadOptions: [
                LiveThreadOption(id: "thread-a", title: "A", updatedAtMS: 1, rolloutPath: "/tmp/a.jsonl")
            ]
        )
        monitor.testProcessPollInputs(
            streamRows: [
                LiveRateMonitor.LogRow(
                    id: 1,
                    threadID: "thread-a",
                    ts: 1_000,
                    tsNanos: 0,
                    target: "codex_api::sse::responses",
                    feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"old source output","item_id":"msg-a","sequence_number":1}"#
                )
            ],
            rolloutReads: [
                LiveRateMonitor.RolloutRead(
                    threadID: "thread-a",
                    path: "/tmp/a.jsonl",
                    newOffset: 10,
                    events: [RolloutMetricEvent(timestamp: 1_000.1, key: "rollout-a", category: .visibleText, text: "old rollout")]
                )
            ],
            now: 1_000.2
        )
        XCTAssertGreaterThan(monitor.snapshot.breakdown.visibleText, 0)
        XCTAssertGreaterThan(monitor.totalSnapshot.breakdown.visibleText, 0)
        XCTAssertEqual(monitor.selectedThreadID, "thread-a")
        XCTAssertEqual(monitor.threadOptions.map(\.id), ["thread-a"])

        monitor.setDataSource(sourceB)

        XCTAssertEqual(monitor.snapshot.threadID, "")
        XCTAssertEqual(monitor.selectedThreadID, "")
        XCTAssertTrue(monitor.threadOptions.isEmpty)
        XCTAssertEqual(monitor.snapshot.breakdown, LiveTokenBreakdown())
        XCTAssertEqual(monitor.totalSnapshot.breakdown, LiveTokenBreakdown())
        XCTAssertTrue(monitor.testTotalSessionRateKeys.isEmpty)
        XCTAssertTrue(monitor.snapshot.sourceLabel.contains(sourceB.codexHome.lastPathComponent))
        XCTAssertTrue(monitor.totalSnapshot.sourceLabel.contains(sourceB.codexHome.lastPathComponent))
    }

    @MainActor
    func testUnchangedDataSourceDoesNotResetLiveRateState() throws {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        let source = try makeCodexDataSource(named: "same-source")
        monitor.setDataSource(source)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-1")
        monitor.testProcessPollInputs(
            streamRows: [
                LiveRateMonitor.LogRow(
                    id: 1,
                    threadID: "thread-1",
                    ts: 1_000,
                    tsNanos: 0,
                    target: "codex_api::sse::responses",
                    feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"kept output","item_id":"msg-keep","sequence_number":1}"#
                )
            ],
            rolloutReads: [],
            now: 1_000.2
        )
        let visibleText = monitor.snapshot.breakdown.visibleText
        XCTAssertGreaterThan(visibleText, 0)

        monitor.setDataSource(source)

        XCTAssertEqual(monitor.selectedThreadID, "thread-1")
        XCTAssertEqual(monitor.snapshot.breakdown.visibleText, visibleText)
        XCTAssertGreaterThan(monitor.snapshot.rollingTokensPerSecond, 0)
    }

    @MainActor
    func testEquivalentStableSourceIdentityDoesNotResetLiveRateState() throws {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        let source = try makeCodexDataSource(named: "same-stable-source")
        let equivalentSource = CodexDataSource(
            codexHome: source.codexHome,
            origin: .defaultHome,
            expectedHomeIdentity: source.homeIdentity
        )
        monitor.setDataSource(source)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-stable")

        XCTAssertFalse(monitor.setDataSource(equivalentSource))
        XCTAssertEqual(monitor.selectedThreadID, "thread-stable")
        XCTAssertEqual(monitor.currentDataSourceIdentity, source.stableIdentityKey)
    }

    @MainActor
    func testSameIdentityPathRebindUpdatesLivePathsWithoutResettingRateState() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRatePathRebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        temporaryDirectories.append(parent)
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.setDataSource(sourceAtOldPath)
        monitor.testPrepareForLiveRateProcessing(
            selectedThreadID: "thread-rebind",
            threadOptions: [
                LiveThreadOption(
                    id: "thread-rebind",
                    title: "Rebind",
                    updatedAtMS: 1,
                    rolloutPath: oldHome.appendingPathComponent("sessions/rebind.jsonl").path
                )
            ]
        )
        monitor.testProcessPollInputs(
            streamRows: [
                LiveRateMonitor.LogRow(
                    id: 1,
                    threadID: "thread-rebind",
                    ts: 1_000,
                    tsNanos: 0,
                    target: "codex_api::sse::responses",
                    feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"keep this rate","item_id":"msg-rebind","sequence_number":1}"#
                )
            ],
            rolloutReads: [],
            now: 1_000.2
        )
        let generationBefore = monitor.testSourceGeneration
        let breakdownBefore = monitor.snapshot.breakdown
        let rateBefore = monitor.snapshot.rollingTokensPerSecond

        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)

        XCTAssertTrue(monitor.setDataSource(sourceAtNewPath))

        XCTAssertEqual(monitor.dataSource?.codexHome.path, newHome.path)
        XCTAssertEqual(
            monitor.cachedLogsDatabasePath,
            newHome.appendingPathComponent("logs_2.sqlite").path
        )
        XCTAssertEqual(monitor.cachedLogsDirectoryPath, newHome.path)
        XCTAssertEqual(monitor.snapshot.sourceLabel, "\(sourceAtNewPath.displayPath)/logs_2.sqlite")
        XCTAssertEqual(monitor.selectedThreadID, "thread-rebind")
        XCTAssertEqual(monitor.threadOptions.first?.rolloutPath, newHome.appendingPathComponent("sessions/rebind.jsonl").path)
        XCTAssertEqual(monitor.snapshot.breakdown, breakdownBefore)
        XCTAssertEqual(monitor.snapshot.rollingTokensPerSecond, rateBefore)
        XCTAssertEqual(monitor.testSourceGeneration, generationBefore)
    }

    @MainActor
    func testNilSourceTransitionClearsLiveStateAndRejectsLateSourceACompletion() throws {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        let sourceA = try makeCodexDataSource(named: "late-live-source-a")
        let sourceB = try makeCodexDataSource(named: "late-live-source-b")
        monitor.setDataSource(sourceA)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-a")
        let sourceAGeneration = monitor.testSourceGeneration

        XCTAssertTrue(monitor.setDataSource(nil))
        XCTAssertNil(monitor.currentDataSourceIdentity)
        XCTAssertEqual(monitor.selectedThreadID, "")
        XCTAssertEqual(monitor.snapshot.breakdown, LiveTokenBreakdown())

        let accepted = monitor.testApplyPollCompletion(
            streamRows: [
                LiveRateMonitor.LogRow(
                    id: 99,
                    threadID: "thread-a",
                    ts: 2_000,
                    tsNanos: 0,
                    target: "codex_api::sse::responses",
                    feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"late source A","item_id":"msg-late","sequence_number":1}"#
                )
            ],
            rolloutReads: [],
            sourceGeneration: sourceAGeneration,
            now: 2_000.2
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(monitor.snapshot.breakdown, LiveTokenBreakdown())
        XCTAssertTrue(monitor.setDataSource(sourceB))
        XCTAssertEqual(monitor.currentDataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertEqual(monitor.selectedThreadID, "")
    }

    @MainActor
    func testDataSourceSwitchAllowsSameFingerprintFromNewSourceToCount() throws {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        let sourceA = try makeCodexDataSource(named: "fingerprint-source-a")
        let sourceB = try makeCodexDataSource(named: "fingerprint-source-b")
        let row = LiveRateMonitor.LogRow(
            id: 1,
            threadID: "thread-1",
            ts: 1_000,
            tsNanos: 0,
            target: "codex_api::sse::responses",
            feedbackLogBody: #"SSE event: {"type":"response.output_text.delta","delta":"same visible","item_id":"msg-1","sequence_number":1}"#
        )

        monitor.setDataSource(sourceA)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-1")
        monitor.testProcessPollInputs(streamRows: [row], rolloutReads: [], now: 1_000.2)
        XCTAssertEqual(
            monitor.totalSnapshot.breakdown.visibleText,
            monitor.estimateTokenCount("same visible", category: .visibleText)
        )

        monitor.setDataSource(sourceB)
        XCTAssertEqual(monitor.totalSnapshot.breakdown, LiveTokenBreakdown())
        monitor.testProcessPollInputs(streamRows: [row], rolloutReads: [], now: 1_001.2)

        XCTAssertEqual(
            monitor.totalSnapshot.breakdown.visibleText,
            monitor.estimateTokenCount("same visible", category: .visibleText)
        )
    }

    @MainActor
    func testUnattributedStreamEventsUseOneStableDisplayBucket() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "selected-thread")
        let first = LiveRateMonitor.LogRow(
            id: 1,
            threadID: nil,
            ts: 1_000,
            tsNanos: 0,
            target: "log",
            feedbackLogBody: #"Received message {"type":"response.output_text.delta","delta":"one","item_id":"msg-a","sequence_number":1}"#
        )
        let second = LiveRateMonitor.LogRow(
            id: 2,
            threadID: nil,
            ts: 1_000,
            tsNanos: 100_000_000,
            target: "log",
            feedbackLogBody: #"Received message {"type":"response.output_text.delta","delta":"two","item_id":"msg-b","sequence_number":1}"#
        )

        monitor.testProcessPollInputs(streamRows: [first, second], rolloutReads: [], now: 1_000.2)

        XCTAssertEqual(monitor.testTotalSessionRateKeys, [LiveRateMonitor.unattributedLiveRateSessionKey])
    }

    @MainActor
    func testInactiveTotalSessionRateBucketsAreEvictedAfterWindowExpires() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "thread-1")
        let first = RolloutMetricEvent(timestamp: 1_000, key: "msg-1", category: .visibleText, text: "first")
        let second = RolloutMetricEvent(timestamp: 1_000, key: "msg-2", category: .visibleText, text: "second")

        monitor.testProcessPollInputs(
            streamRows: [],
            rolloutReads: [
                LiveRateMonitor.RolloutRead(threadID: "thread-1", path: "/tmp/one.jsonl", newOffset: 1, events: [first]),
                LiveRateMonitor.RolloutRead(threadID: "thread-2", path: "/tmp/two.jsonl", newOffset: 1, events: [second])
            ],
            now: 1_000.1
        )
        XCTAssertEqual(monitor.testTotalSessionRateKeys, ["thread-1", "thread-2"])

        monitor.testRefreshSnapshots(now: 1_004)

        XCTAssertTrue(monitor.testTotalSessionRateKeys.isEmpty)
    }

    func testDisplayBucketIgnoresHighSpeedDecimalNoise() {
        XCTAssertEqual(LiveRateMonitor.displayBucket(40.1), LiveRateMonitor.displayBucket(40.4))
        XCTAssertNotEqual(LiveRateMonitor.displayBucket(40.4), LiveRateMonitor.displayBucket(40.6))
        XCTAssertNotEqual(LiveRateMonitor.displayBucket(9.4), LiveRateMonitor.displayBucket(9.6))
    }

    func testRolloutParserDoesNotCountAgentMessageDuplicateAsInstantRollingOutput() {
        let text = String(repeating: "streamed answer ", count: 200)
        let lines = [
            rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: text),
            rolloutAssistantResponseItemLine(timestamp: "2026-06-24T13:00:00.010Z", id: "msg-1", text: text)
        ]

        let events = LiveRateMonitor.rolloutEvents(fromLines: lines)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, text)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertEqual(events.first?.rollingOnly, false)
    }

    func testRolloutParserCountsCompleteAgentMessageWhileAssistantItemIsStillBuffered() {
        let text = "可以，先按这个修。"
        let events = LiveRateMonitor.rolloutEvents(fromLines: [
            rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: text)
        ])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, text)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertEqual(events.first?.rollingOnly, false)
    }

    func testRolloutParserSkipsMalformedAndMissingTimestamps() throws {
        let malformedTimestampLine = rolloutAgentMessageLine(timestamp: "not-a-date", message: "bad timestamp")
        let missingTimestampLine = jsonLine([
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "message": "missing timestamp"
            ]
        ])
        let validLine = rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: "valid timestamp")

        let events = LiveRateMonitor.rolloutEvents(fromLines: [
            malformedTimestampLine,
            missingTimestampLine,
            validLine
        ])

        XCTAssertEqual(events.map(\.text), ["valid timestamp"])
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.timestamp, 1_782_306_000, accuracy: 0.001)
    }

    func testRolloutParserCountsToolInputPayloadsButIgnoresToolResultsForLiveRateFallback() throws {
        let events = LiveRateMonitor.rolloutEvents(fromLines: [
            rolloutCustomToolCallLine(timestamp: "2026-06-24T13:00:00.000Z", id: "tool-1", name: "exec_command", input: #"{"cmd":"date"}"#),
            rolloutCustomToolCallLine(timestamp: "2026-06-24T13:00:00.500Z", id: "tool-2", name: "apply_patch", input: "diff --git a/file b/file"),
            rolloutFunctionCallOutputLine(timestamp: "2026-06-24T13:00:01.000Z", callID: "tool-1", output: "tool result"),
            rolloutPatchApplyEndLine(timestamp: "2026-06-24T13:00:02.000Z", content: "diff --git a/file b/file")
        ])

        XCTAssertEqual(events.count, 2)
        let toolEvent = try XCTUnwrap(events.first)
        XCTAssertEqual(toolEvent.text, #"{"cmd":"date"}"#)
        XCTAssertEqual(toolEvent.category, .toolArguments)
        XCTAssertTrue(try XCTUnwrap(toolEvent.category).contributesToLiveRate)
        let patchEvent = try XCTUnwrap(events.dropFirst().first)
        XCTAssertEqual(patchEvent.text, "diff --git a/file b/file")
        XCTAssertEqual(patchEvent.category, .patchInput)
        XCTAssertTrue(try XCTUnwrap(patchEvent.category).contributesToLiveRate)
    }

    func testRolloutParserIgnoresTokenCountPayloadForTemporaryLiveRateIsolation() {
        let events = LiveRateMonitor.rolloutEvents(fromLines: [
            rolloutTokenCountLine(timestamp: "2026-06-24T13:00:00.000Z", outputTokens: 240, reasoningTokens: 80)
        ])

        XCTAssertTrue(events.isEmpty)
    }

    func testRolloutReadsSkipUnchangedFilesBeforeOpeningAndStillReadAppends() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRateMonitorRollout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let firstLine = rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: "first")
        try (firstLine + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)
        let currentOffset = UInt64(try Data(contentsOf: rolloutURL).count)
        let option = LiveThreadOption(
            id: "thread-1",
            title: "Thread",
            updatedAtMS: 0,
            rolloutPath: rolloutURL.path
        )

        let unchangedReads = try LiveRateMonitor.rolloutReads(
            options: [option],
            offsets: [rolloutURL.path: currentOffset]
        )

        XCTAssertEqual(unchangedReads.count, 1)
        XCTAssertEqual(unchangedReads[0].newOffset, currentOffset)
        XCTAssertTrue(unchangedReads[0].events.isEmpty)

        let appendedLine = rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:01.000Z", message: "second")
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLine + "\n").utf8))
        try handle.close()

        let appendedReads = try LiveRateMonitor.rolloutReads(
            options: [option],
            offsets: [rolloutURL.path: currentOffset]
        )

        XCTAssertEqual(appendedReads.count, 1)
        XCTAssertGreaterThan(appendedReads[0].newOffset, currentOffset)
        XCTAssertEqual(appendedReads[0].events.map(\.text), ["second"])
    }

    func testRolloutReadsRestartFromBeginningWhenFileShrinksBelowStoredOffset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRateMonitorRollout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let originalLine = rolloutAgentMessageLine(
            timestamp: "2026-06-24T13:00:00.000Z",
            message: String(repeating: "older content ", count: 20)
        )
        try (originalLine + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)
        let previousOffset = UInt64(try Data(contentsOf: rolloutURL).count)
        let replacementLine = rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:01.000Z", message: "new")
        try (replacementLine + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)
        let replacementOffset = UInt64(try Data(contentsOf: rolloutURL).count)
        XCTAssertLessThan(replacementOffset, previousOffset)
        let option = LiveThreadOption(
            id: "thread-1",
            title: "Thread",
            updatedAtMS: 0,
            rolloutPath: rolloutURL.path
        )

        let reads = try LiveRateMonitor.rolloutReads(
            options: [option],
            offsets: [rolloutURL.path: previousOffset]
        )

        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads[0].newOffset, replacementOffset)
        XCTAssertEqual(reads[0].events.map(\.text), ["new"])
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRateMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("logs.sqlite")
    }

    private func makeCodexDataSource(named name: String) throws -> CodexDataSource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRateMonitorSource-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return CodexDataSource(codexHome: directory, origin: .userSelected)
    }

    private func insertLog(
        driver: SQLiteDatabaseDriver,
        id: Int,
        threadID: String? = "thread-1",
        target: String = "codex_api::endpoint::responses_websocket",
        body: String
    ) throws {
        try driver.execute(
            """
            INSERT INTO logs (id, thread_id, ts, ts_nanos, target, feedback_log_body)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int(id),
                threadID.map(SQLiteBinding.text) ?? .null,
                .int(1_000 + id),
                .int(0),
                .text(target),
                .text(body)
            ]
        )
    }

    private func rolloutAgentMessageLine(timestamp: String, message: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "message": message
            ]
        ])
    }

    private func rolloutAssistantResponseItemLine(timestamp: String, id: String, text: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": id,
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": text
                    ]
                ]
            ]
        ])
    }

    private func rolloutCustomToolCallLine(timestamp: String, id: String, name: String, input: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "id": id,
                "name": name,
                "input": input
            ]
        ])
    }

    private func rolloutFunctionCallOutputLine(timestamp: String, callID: String, output: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ])
    }

    private func rolloutPatchApplyEndLine(timestamp: String, content: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "patch_apply_end",
                "changes": [
                    "file": [
                        "content": content
                    ]
                ]
            ]
        ])
    }

    private func rolloutTokenCountLine(timestamp: String, outputTokens: Int, reasoningTokens: Int) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "output_tokens": outputTokens,
                        "reasoning_output_tokens": reasoningTokens
                    ]
                ]
            ]
        ])
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
