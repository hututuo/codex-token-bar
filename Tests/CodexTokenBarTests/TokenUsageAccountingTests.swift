import Foundation
import XCTest
@testable import CodexTokenBar

final class TokenUsageAccountingTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUsageAccountingUsesInputPlusOutputAndDoesNotDoubleCountReasoning() throws {
        let components = UsageAccountingComponents(
            input: 100,
            cached: 40,
            output: 10,
            reasoning: 7
        )

        XCTAssertTrue(components.isValid)
        XCTAssertEqual(components.total, 110)

        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: nil,
                last: usage(
                    input: 100,
                    cached: 40,
                    output: 10,
                    reasoning: 7,
                    reportedTotal: nil
                )
            )
        ])
        let capture = try parse(analyzer: analyzer, file: file)
        let event = try XCTUnwrap(capture.events.first)

        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(event.tokens, 110)
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.cachedInputTokens, 40)
        XCTAssertEqual(event.outputTokens, 10)
        XCTAssertEqual(event.reasoningOutputTokens, 7)
        XCTAssertEqual(event.kind, UsageAccountingKind.counted.rawValue)
        XCTAssertNil(event.reportedTotalTokens)
    }

    func testPartialUsageFingerprintMatchesSharedRustContractVector() throws {
        // Keep this timestamp literal: ISO8601DateFormatter normalizes away
        // the six fractional digits that are part of the cross-language
        // partial-snapshot identity contract.
        let rawLine = #"{"timestamp":"2026-09-05T01:00:00.123456Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [rawLine])
        var fingerprints: [CodexUsageAnalyzer.UsageSnapshotFingerprint] = []

        let capture = try parse(analyzer: analyzer, file: file) { fingerprint in
            fingerprints.append(fingerprint)
            return true
        }

        let fingerprint = try XCTUnwrap(fingerprints.first)
        let encoded = try JSONEncoder().encode(fingerprint)
        let vector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [Int]
        )
        XCTAssertEqual(
            vector,
            [
                3_055_952_699,
                2_187_296_764,
                1_175_716_159,
                614_398_934,
                4_030_878_752,
                0,
                1_501_025_032,
                3_640_361_036,
                3_087_568_809,
                0,
                1
            ]
        )
        XCTAssertEqual(capture.events.map(\.tokens), [110])
        XCTAssertEqual(
            capture.events.map(\.kind),
            [UsageAccountingKind.counted.rawValue]
        )
    }

    func testTotalOnly53707DoesNotBillAndFollowingCompleteCumulativeUsageCounts57590() throws {
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: usage(
                    input: 0,
                    cached: 0,
                    output: 0,
                    reasoning: 0,
                    reportedTotal: 53_707
                ),
                last: nil
            ),
            tokenCountLine(
                at: 2,
                total: usage(
                    input: 57_038,
                    cached: 18_176,
                    output: 552,
                    reasoning: 447,
                    reportedTotal: 57_590
                ),
                last: nil
            )
        ])

        let capture = try parse(analyzer: analyzer, file: file)
        XCTAssertEqual(capture.events.count, 2)
        XCTAssertEqual(capture.events.map(\.tokens), [0, 57_590])
        XCTAssertEqual(
            capture.events.map(\.kind),
            [UsageAccountingKind.reportedOnly.rawValue, UsageAccountingKind.counted.rawValue]
        )
        XCTAssertEqual(capture.events.map(\.reportedTotalTokens), [53_707, 57_590])
        let counted = try XCTUnwrap(capture.events.last)
        XCTAssertEqual(counted.inputTokens, 57_038)
        XCTAssertEqual(counted.cachedInputTokens, 18_176)
        XCTAssertEqual(counted.outputTokens, 552)
        XCTAssertEqual(counted.reasoningOutputTokens, 447)
        XCTAssertEqual(
            capture.events
                .filter { $0.kind == UsageAccountingKind.counted.rawValue }
                .reduce(0) { $0 + $1.tokens },
            57_590
        )
    }

    func testCumulativeFallbackUsesComponentDeltas() throws {
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110),
                last: nil
            ),
            tokenCountLine(
                at: 2,
                total: usage(input: 130, cached: 50, output: 20, reasoning: 5, reportedTotal: 150),
                last: nil
            ),
            tokenCountLine(
                at: 3,
                total: usage(input: 160, cached: 60, output: 25, reasoning: 6, reportedTotal: 185),
                last: nil
            )
        ])

        let capture = try parse(analyzer: analyzer, file: file)
        XCTAssertEqual(capture.events.map(\.tokens), [110, 40, 35])
        XCTAssertEqual(capture.events.map(\.inputTokens), [100, 30, 30])
        XCTAssertEqual(capture.events.map(\.cachedInputTokens), [40, 10, 10])
        XCTAssertEqual(capture.events.map(\.outputTokens), [10, 10, 5])
        XCTAssertEqual(capture.events.map(\.reasoningOutputTokens), [2, 3, 1])
        XCTAssertEqual(capture.events.map(\.kind), Array(repeating: UsageAccountingKind.counted.rawValue, count: 3))
    }

    func testLastOnlyThenCumulativeSnapshotDoesNotDoubleCount() throws {
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: nil,
                last: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: nil)
            ),
            tokenCountLine(
                at: 2,
                total: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110),
                last: nil
            ),
            tokenCountLine(
                at: 3,
                total: usage(input: 130, cached: 50, output: 20, reasoning: 5, reportedTotal: 150),
                last: nil
            )
        ])

        let capture = try parse(analyzer: analyzer, file: file)
        XCTAssertEqual(capture.events.map(\.tokens), [110, 40])
        XCTAssertEqual(capture.events.map(\.inputTokens), [100, 30])
        XCTAssertEqual(capture.events.map(\.cachedInputTokens), [40, 10])
        XCTAssertEqual(capture.events.map(\.outputTokens), [10, 10])
        XCTAssertEqual(capture.events.map(\.reasoningOutputTokens), [2, 3])
        XCTAssertEqual(capture.events.map(\.reportedTotalTokens), [nil, 150])
    }

    func testCumulativeResetAllowsARealRequestWithTheSameLastTuple() throws {
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: usage(input: 200, cached: 80, output: 20, reasoning: 4, reportedTotal: 220),
                last: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110)
            ),
            // The cumulative counter moves backwards, while the real request
            // has the same last tuple as the preceding request.
            tokenCountLine(
                at: 2,
                total: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110),
                last: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110)
            )
        ])
        var callbackCount = 0
        let capture = try parse(analyzer: analyzer, file: file) { _ in
            callbackCount += 1
            return true
        }

        XCTAssertEqual(capture.events.map(\.tokens), [110, 110])
        XCTAssertEqual(capture.events.map(\.inputTokens), [100, 100])
        XCTAssertEqual(capture.events.map(\.cachedInputTokens), [40, 40])
        XCTAssertEqual(capture.events.map(\.outputTokens), [10, 10])
        XCTAssertEqual(capture.events.map(\.reasoningOutputTokens), [2, 2])
        XCTAssertEqual(capture.events.map(\.kind), Array(repeating: UsageAccountingKind.counted.rawValue, count: 2))
        XCTAssertEqual(callbackCount, 2)
    }

    func testCheckpointRoundTripAndAppendMatchCompleteParse() throws {
        let prefixLines = [
            tokenCountLine(
                at: 1,
                total: nil,
                last: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: nil)
            ),
            tokenCountLine(
                at: 2,
                total: usage(input: 100, cached: 40, output: 10, reasoning: 2, reportedTotal: 110),
                last: nil
            )
        ]
        let appendedLine = tokenCountLine(
            at: 3,
            total: usage(input: 130, cached: 50, output: 20, reasoning: 5, reportedTotal: 150),
            last: nil
        )
        let (analyzer, file) = try makeAnalyzerAndSession(lines: prefixLines)
        let prefixSize = try fileSize(of: file)
        let prefixCapture = try parse(analyzer: analyzer, file: file)
        let prefixState = try XCTUnwrap(prefixCapture.result.state.accountingState)
        let restoredState = try XCTUnwrap(try UsageAccountingState.decode(prefixState.encoded))
        XCTAssertEqual(restoredState, prefixState)

        try appendLine(appendedLine, to: file)
        let fullCapture = try parse(analyzer: analyzer, file: file)

        var appendState = prefixCapture.result.state
        appendState.accountingState = restoredState
        let appendRequest = CodexUsageAnalyzer.IndexedSessionParseRequest(
            hashingStartOffset: 0,
            parsingStartOffset: prefixSize,
            endOffset: try fileSize(of: file),
            validationBoundary: nil,
            initialState: appendState,
            readHandle: nil
        )
        let appendCapture = try parse(
            analyzer: analyzer,
            file: file,
            request: appendRequest
        )
        XCTAssertEqual(prefixCapture.events.map(\.tokens), [110])
        XCTAssertEqual(appendCapture.events.map(\.tokens), [40])
        XCTAssertEqual(
            prefixCapture.events + appendCapture.events,
            fullCapture.events,
            "serialized checkpoint + suffix parsing must equal a complete parse"
        )
        XCTAssertEqual(
            appendCapture.result.state.accountingState,
            fullCapture.result.state.accountingState
        )
    }

    func testInvalidCacheAndNegativeNumbersRemainDiagnosticWithoutBilling() throws {
        let (analyzer, file) = try makeAnalyzerAndSession(lines: [
            tokenCountLine(
                at: 1,
                total: nil,
                last: usage(input: 10, cached: 11, output: 3, reasoning: 1, reportedTotal: 24)
            ),
            tokenCountLine(
                at: 2,
                total: nil,
                last: usage(input: -1, cached: 0, output: 3, reasoning: 0, reportedTotal: 2)
            )
        ])

        let capture = try parse(analyzer: analyzer, file: file)
        XCTAssertEqual(capture.events.count, 2)
        XCTAssertEqual(capture.events.map(\.tokens), [0, 0])
        XCTAssertEqual(
            capture.events.map(\.kind),
            Array(repeating: UsageAccountingKind.invalid.rawValue, count: 2)
        )
        XCTAssertEqual(capture.events.map(\.cachedInputTokens), [11, 0])
        XCTAssertEqual(capture.events.map(\.outputTokens), [3, 3])
        XCTAssertEqual(
            capture.events
                .filter { $0.kind == UsageAccountingKind.counted.rawValue }
                .reduce(0) { $0 + $1.tokens },
            0
        )
    }

    func testNonIntegerJSONSpellingsAreDiagnosticInBothParsers() throws {
        let spellings = ["1.0", "1e3", "-0", "\"-0\"", "1.5"]
        let lines = spellings.enumerated().map { index, spelling in
            "{\"timestamp\":\"2026-09-05T01:00:0\(index)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(spelling),\"output_tokens\":1}}}}"
        }
        let (analyzer, file) = try makeAnalyzerAndSession(lines: lines)
        let capture = try parse(analyzer: analyzer, file: file)
        XCTAssertEqual(capture.events.count, spellings.count)
        XCTAssertEqual(capture.events.map(\.tokens), Array(repeating: 0, count: spellings.count))
        XCTAssertEqual(capture.events.map(\.kind), Array(repeating: UsageAccountingKind.invalid.rawValue, count: spellings.count))
        let decoy = #"{"payload":{"info":{"note":"colon: -0, is text","last_token_usage":{"input_tokens":0,"output_tokens":1}}},"metadata":{"input_tokens":-0}}"#
        XCTAssertEqual(TokenUsageLexicalValidation.negativeZeroFields(in: decoy), [:])
    }

    private struct UsageFixture {
        let input: Int?
        let cached: Int?
        let output: Int?
        let reasoning: Int?
        let reportedTotal: Int?

        var object: [String: Int] {
            var values: [String: Int] = [:]
            if let input { values["input_tokens"] = input }
            if let cached { values["cached_input_tokens"] = cached }
            if let output { values["output_tokens"] = output }
            if let reasoning { values["reasoning_output_tokens"] = reasoning }
            if let reportedTotal { values["total_tokens"] = reportedTotal }
            return values
        }
    }

    private struct EmittedEvent: Equatable {
        let tokens: Int
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let kind: Int
        let reportedTotalTokens: Int?

        init(_ event: CodexUsageAnalyzer.IndexedTokenEvent) {
            tokens = event.event.tokens
            inputTokens = event.event.inputTokens
            cachedInputTokens = event.event.cachedInputTokens
            outputTokens = event.event.outputTokens
            reasoningOutputTokens = event.event.reasoningOutputTokens
            kind = event.accountingKind.rawValue
            reportedTotalTokens = event.reportedTotalTokens
        }
    }

    private struct ParseCapture {
        let result: CodexUsageAnalyzer.IndexedSessionParseResult
        let events: [EmittedEvent]
    }

    private func usage(
        input: Int? = nil,
        cached: Int? = nil,
        output: Int? = nil,
        reasoning: Int? = nil,
        reportedTotal: Int? = nil
    ) -> UsageFixture {
        UsageFixture(
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            reportedTotal: reportedTotal
        )
    }

    private func tokenCountLine(
        at seconds: TimeInterval,
        total: UsageFixture?,
        last: UsageFixture?
    ) -> String {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total.object }
        if let last { info["last_token_usage"] = last.object }
        let object: [String: Any] = [
            "timestamp": iso8601Formatter.string(from: Date(timeIntervalSince1970: seconds)),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": info
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeAnalyzerAndSession(lines: [String]) throws -> (CodexUsageAnalyzer, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageAccountingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(home)
        let file = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-09-06-accounting-fixture.jsonl")
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        try data.write(to: file, options: .atomic)
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        return (CodexUsageAnalyzer(dataSource: source), file)
    }

    private func parse(
        analyzer: CodexUsageAnalyzer,
        file: URL,
        request: CodexUsageAnalyzer.IndexedSessionParseRequest? = nil,
        fingerprintPolicy: @escaping (CodexUsageAnalyzer.UsageSnapshotFingerprint) throws -> Bool = { _ in true }
    ) throws -> ParseCapture {
        let parseRequest = try request ?? .full(endOffset: fileSize(of: file))
        var events: [EmittedEvent] = []
        let result = try analyzer.parseSessionIntoHistoryIndex(
            file: file,
            sessionID: "accounting-fixture-session",
            request: parseRequest,
            insertFingerprint: fingerprintPolicy,
            emit: { events.append(EmittedEvent($0)) }
        )
        return ParseCapture(result: result, events: events)
    }

    private func appendLine(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.appending("\n").utf8))
        try handle.close()
    }

    private func fileSize(of file: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
    }
}
