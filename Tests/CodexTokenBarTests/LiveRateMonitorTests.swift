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

    func testPollReadsRolloutJsonlWhenSqliteStreamHasNoNewRows() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)

        XCTAssertTrue(monitorSource.contains("await readRolloutUpdates(now:"))
    }

    func testPollStillReadsRolloutJsonlAfterSqliteStreamRows() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)

        let globalRowsRange = try XCTUnwrap(monitorSource.range(of: "for row in globalRows {"))
        let rolloutRange = try XCTUnwrap(
            monitorSource.range(
                of: "await readRolloutUpdates(now:",
                range: globalRowsRange.upperBound..<monitorSource.endIndex
            )
        )
        let snapshotRange = try XCTUnwrap(
            monitorSource.range(
                of: "updateSnapshots(now:",
                range: rolloutRange.upperBound..<monitorSource.endIndex
            )
        )

        XCTAssertLessThan(rolloutRange.lowerBound, snapshotRange.lowerBound)
    }

    func testPollUsesRolloutOnlyWhenSqliteRowsHaveNoUsableStreamMetrics() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)

        XCTAssertTrue(monitorSource.contains("var processedStreamEvents = false"))
        XCTAssertTrue(monitorSource.contains("if add(row: row) {"))
        XCTAssertTrue(monitorSource.contains("if !processedStreamEvents {"))
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

    func testFastDisplayWindowDoesNotForceEveryTickDataSourceReads() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)
        let shouldPollLogsRange = try XCTUnwrap(monitorSource.range(of: "let shouldPollLogs ="))
        let shouldReadRolloutRange = try XCTUnwrap(monitorSource.range(of: "let shouldReadRollout ="))
        let guardRange = try XCTUnwrap(
            monitorSource.range(
                of: "guard shouldPollLogs || shouldReadRollout else",
                range: shouldReadRolloutRange.upperBound..<monitorSource.endIndex
            )
        )
        let dataReadGate = monitorSource[shouldPollLogsRange.lowerBound..<guardRange.lowerBound]

        XCTAssertFalse(dataReadGate.contains("now < fastPollUntil"))
        XCTAssertFalse(dataReadGate.contains("hasActiveRollingWindow"))
        XCTAssertTrue(dataReadGate.contains("hasLogChangeSignal"))
        XCTAssertTrue(dataReadGate.contains("idleFallbackPollInterval"))
        XCTAssertTrue(dataReadGate.contains("rolloutFallbackPollInterval"))
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

    func testLiveRateSnapshotFormatsLowSpeedPreciselyAndHighSpeedCoarsely() {
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(0), "0.0")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(9.64), "9.6")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(40.4), "40")
        XCTAssertEqual(LiveRateSnapshot.rateDisplayText(40.6), "41")
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
