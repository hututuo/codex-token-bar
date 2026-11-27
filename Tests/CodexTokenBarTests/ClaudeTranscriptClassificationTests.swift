import Foundation
import XCTest
@testable import CodexTokenBar

/// Candidate classifier coverage only. These tests do not exercise discovery or
/// establish any migration behavior for records already stored in a ledger.
final class ClaudeTranscriptClassificationTests: XCTestCase {
    private static let fastPathBytes = 65_536
    private static let maximumBytes = 16_777_216

    func testShortExplicitHeaderUsesOne4KiBRead() throws {
        let header = Data((#"{"entrypoint":"claude-desktop"}"# + "\n").utf8)
        var bytes = header
        bytes.append(Data(repeating: 0x78, count: 8_192))
        let reader = RecordingReader(bytes)

        let result = try ClaudeTranscriptClassification.classify(read: reader.read)

        XCTAssertEqual(reader.requests, [4_096])
        XCTAssertEqual(reader.offset, 4_096)
        XCTAssertEqual(result.bytesRead, 4_096)
        XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: header.count))
        XCTAssertEqual(result.client, .claudeDesktop)
        XCTAssertEqual(result.delimiterBytesExamined, header.count)
        assertLinearInspection(result)
    }

    func testPaddedValidJSONFindsEntrypointBeforeAndAfterContent() throws {
        try assertExplicitRecord(bytes: Self.fastPathBytes + 8_192)
    }

    func testExactly64KiBRecordIncludesLFAndIsExplicit() throws {
        try assertExplicitRecord(bytes: Self.fastPathBytes)
    }

    func test64KiBPlusOneRecordIncludesLFAndIsExplicit() throws {
        try assertExplicitRecord(bytes: Self.fastPathBytes + 1)
    }

    func test1MiBRecordIncludesLFAndIsExplicit() throws {
        try assertExplicitRecord(bytes: 1_048_576)
    }

    func testExactly4MiBRecordIncludesLFAndIsExplicit() throws {
        try assertExplicitRecord(bytes: 4_194_304)
    }

    func testExactly16MiBRecordIncludesLFAndIsExplicit() throws {
        try assertExplicitRecord(bytes: Self.maximumBytes)
    }

    func test16MiBPlusOneRecordRemainsIncompleteAtTotalBudget() throws {
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            try autoreleasepool {
                let bytes = try paddedRecord(bytes: Self.maximumBytes + 1, placement: placement)
                XCTAssertEqual(bytes.last, 0x0A)
                XCTAssertFalse(bytes.prefix(Self.maximumBytes).contains(0x0A))
                let reader = RecordingReader(bytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .incomplete(.byteLimit))
                XCTAssertNil(result.client)
                XCTAssertEqual(result.bytesRead, Self.maximumBytes)
                XCTAssertEqual(reader.offset, Self.maximumBytes)
                XCTAssertEqual(result.delimiterBytesExamined, Self.maximumBytes)
                XCTAssertEqual(result.unfinishedRecordBytes, Self.maximumBytes)
                assertLinearInspection(result)
            }
        }
    }

    func testByteLimitAppliesToTotalPrefixAcrossCompleteLines() throws {
        let completeLine = try paddedRecord(bytes: 4_194_304, placement: .absent)
        var bytes = Data()
        for _ in 0..<4 { bytes.append(completeLine) }
        let desktop = Data((#"{"entrypoint":"claude-desktop"}"# + "\n").utf8)
        bytes.append(desktop)
        let reader = RecordingReader(bytes)

        let result = try ClaudeTranscriptClassification.classify(read: reader.read)

        XCTAssertEqual(result.evidence, .incomplete(.byteLimit))
        XCTAssertNil(result.client)
        XCTAssertEqual(result.bytesRead, Self.maximumBytes)
        XCTAssertEqual(reader.offset, Self.maximumBytes)
        XCTAssertEqual(result.delimiterBytesExamined, Self.maximumBytes)
        XCTAssertNil(result.unfinishedRecordBytes)
        XCTAssertEqual(Data(bytes.suffix(desktop.count)), desktop)
        assertLinearInspection(result)
    }

    func testCompleteJSONWithoutLFRemainsPartialForEveryEntrypointShape() throws {
        let bodies = [
            #"{"entrypoint":"claude-desktop"}"#,
            #"{"entrypoint":"cli"}"#,
            #"{"entrypoint":" "}"#,
            #"{"message":{"content":"anonymous"}}"#,
        ]
        for body in bodies {
            _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
            for prefix in ["", "{}\n"] {
                let bytes = Data((prefix + body).utf8)
                let reader = RecordingReader(bytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .incomplete(.partialRecord), body)
                XCTAssertNil(result.client, body)
                XCTAssertEqual(result.bytesRead, bytes.count)
                XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
                XCTAssertEqual(reader.offset, bytes.count)
                assertLinearInspection(result)
            }
        }
    }

    func testCleanEOFAfterInvalidNestedBlankAndMissingEntrypointRecordsUsesLegacyCLI() throws {
        let records = [
            "not JSON\n",
            #"{"entrypoint":"claude-desktop",broken}"# + "\n",
            #"{"message":{"entrypoint":"claude-desktop"}}"# + "\n",
            #"{"entrypoint":" \t\r\n "}"# + "\n",
            #"{"entrypoint":""}"# + "\n",
            #"{"entrypoint":null}"# + "\n",
            #"{"entrypoint":7}"# + "\n",
            #"{"message":{"content":"entrypoint: claude-desktop"}}"# + "\n",
            #"[{"entrypoint":"claude-desktop"}]"# + "\n",
            "\n",
        ]
        for contents in records + [records.joined()] {
            let bytes = Data(contents.utf8)
            let reader = RecordingReader(bytes)

            let result = try ClaudeTranscriptClassification.classify(read: reader.read)

            XCTAssertEqual(result.evidence, .legacyCLI, contents)
            XCTAssertEqual(result.client, .claudeCode, contents)
            XCTAssertEqual(result.bytesRead, bytes.count)
            XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
            XCTAssertEqual(reader.requests.count, 2, "Clean EOF must be observed")
            assertLinearInspection(result)
        }
    }

    func testEmptyCleanEOFUsesLegacyCLI() throws {
        let reader = RecordingReader(Data())

        let result = try ClaudeTranscriptClassification.classify(read: reader.read)

        XCTAssertEqual(result.evidence, .legacyCLI)
        XCTAssertEqual(result.client, .claudeCode)
        XCTAssertEqual(result.bytesRead, 0)
        XCTAssertEqual(result.delimiterBytesExamined, 0)
        XCTAssertEqual(reader.requests, [4_096])
    }

    func testFirstExplicitEntrypointWins() throws {
        let cases: [(first: String, second: String, client: UsageClient)] = [
            ("claude-desktop", "cli", .claudeDesktop),
            ("cli", "claude-desktop", .claudeCode),
            ("claude-desktop-anonymous", "cli", .claudeDesktop),
        ]
        for value in cases {
            let prefix = "{}\n"
            let first = "{\"entrypoint\":\"\(value.first)\"}\n"
            let second = "{\"entrypoint\":\"\(value.second)\"}\n"
            let bytes = Data((prefix + first + second).utf8)
            let reader = RecordingReader(bytes)
            let recordEnd = prefix.utf8.count + first.utf8.count

            let result = try ClaudeTranscriptClassification.classify(read: reader.read)

            XCTAssertEqual(result.evidence, .explicit(client: value.client, recordEnd: recordEnd))
            XCTAssertEqual(result.client, value.client)
            XCTAssertEqual(result.bytesRead, bytes.count)
            XCTAssertEqual(result.delimiterBytesExamined, recordEnd)
            XCTAssertEqual(reader.requests, [4_096])
            assertLinearInspection(result)
        }
    }

    func testBOMAndCRLFAllowExplicitEntrypointsAcrossChunkBoundaries() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let desktop = Data((#"{"entrypoint":"claude-desktop"}"# + "\r\n").utf8)
        let fixtures = [bom + desktop, bom + Data("{}\r\n".utf8) + desktop]
        for bytes in fixtures {
            for returnedBytes in [1, 4_096] {
                let reader = RecordingReader(bytes, maximumReturnedBytes: returnedBytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: bytes.count))
                XCTAssertEqual(result.client, .claudeDesktop)
                XCTAssertEqual(result.bytesRead, bytes.count)
                XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
                assertLinearInspection(result)
            }
        }
    }

    func testDelimiterInspectionIsLinearAcrossManyCompleteLines() throws {
        let line = Data((#"{"message":{"content":"anonymous entrypoint text"}}"# + "\n").utf8)
        var bytes = Data()
        for _ in 0..<2_048 { bytes.append(line) }
        let desktop = Data((#"{"entrypoint":"claude-desktop"}"# + "\n").utf8)
        bytes.append(desktop)
        let recordEnd = bytes.count
        bytes.append(Data(repeating: 0x78, count: 4_096))
        for returnedBytes in [17, 4_096] {
            let reader = RecordingReader(bytes, maximumReturnedBytes: returnedBytes)

            let result = try ClaudeTranscriptClassification.classify(read: reader.read)

            XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: recordEnd))
            XCTAssertEqual(result.delimiterBytesExamined, recordEnd)
            XCTAssertEqual(result.bytesRead, reader.offset)
            assertLinearInspection(result)
        }
    }

    func testDelimiterInspectionDoesNotRevisitLongPartialRecords() throws {
        let bytes = Data(repeating: 0x78, count: 1_048_576)
        for returnedBytes in [31, 4_096] {
            let reader = RecordingReader(bytes, maximumReturnedBytes: returnedBytes)

            let result = try ClaudeTranscriptClassification.classify(read: reader.read)

            XCTAssertEqual(result.evidence, .incomplete(.partialRecord))
            XCTAssertNil(result.client)
            XCTAssertEqual(result.bytesRead, bytes.count)
            XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
            assertLinearInspection(result)
        }
    }

    func testInjectedReaderErrorPropagatesDuringFallback() {
        var returnedBytes = 0
        var requests: [Int] = []

        XCTAssertThrowsError(try ClaudeTranscriptClassification.classify { count in
            requests.append(count)
            guard returnedBytes < Self.fastPathBytes else { throw ReaderFailure.injected }
            returnedBytes += count
            return Data(repeating: 0x78, count: count)
        }) { error in
            XCTAssertEqual(error as? ReaderFailure, .injected)
        }

        XCTAssertEqual(returnedBytes, Self.fastPathBytes)
        XCTAssertEqual(requests, Array(repeating: 4_096, count: 16) + [65_536])
    }

    func testOversizedInjectedReadIsRejected() {
        for failureOffset in [0, Self.fastPathBytes] {
            var returnedBytes = 0
            var requests: [Int] = []

            XCTAssertThrowsError(try ClaudeTranscriptClassification.classify { count in
                requests.append(count)
                if returnedBytes >= failureOffset {
                    return Data(repeating: 0x78, count: count + 1)
                }
                returnedBytes += count
                return Data(repeating: 0x78, count: count)
            }) { error in
                let cocoaError = error as NSError
                XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
                XCTAssertEqual(cocoaError.code, CocoaError.Code.fileReadUnknown.rawValue)
            }

            XCTAssertEqual(returnedBytes, failureOffset)
            XCTAssertEqual(requests.last, failureOffset == 0 ? 4_096 : 65_536)
        }
    }

    func testConfiguredByteLimitStopsBeforeCommittedRecordEnd() throws {
        let bytes = Data((#"{"entrypoint":"claude-desktop"}"# + "\n").utf8)
        let reader = RecordingReader(bytes)

        let incomplete = try ClaudeTranscriptClassification.classify(byteLimit: bytes.count - 1, read: reader.read)

        XCTAssertEqual(incomplete.evidence, .incomplete(.byteLimit))
        XCTAssertNil(incomplete.client)
        XCTAssertEqual(incomplete.bytesRead, bytes.count - 1)
        XCTAssertEqual(reader.requests, [bytes.count - 1])
        assertLinearInspection(incomplete)

        let completeReader = RecordingReader(bytes)
        let complete = try ClaudeTranscriptClassification.classify(byteLimit: bytes.count, read: completeReader.read)
        XCTAssertEqual(complete.evidence, .explicit(client: .claudeDesktop, recordEnd: bytes.count))
        XCTAssertEqual(complete.bytesRead, bytes.count)
        assertLinearInspection(complete)
    }

    func testCompleteRecordsAtByteLimitDoNotAssumeCleanEOF() throws {
        let bytes = Data("{}\n".utf8)
        let reader = RecordingReader(bytes)

        let result = try ClaudeTranscriptClassification.classify(byteLimit: bytes.count, read: reader.read)

        XCTAssertEqual(result.evidence, .incomplete(.byteLimit))
        XCTAssertNil(result.client)
        XCTAssertEqual(result.bytesRead, bytes.count)
        XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
        XCTAssertEqual(reader.requests, [bytes.count])
        assertLinearInspection(result)
    }

    func testConfiguredByteLimitCannotExceedMaximumBytes() throws {
        var returnedBytes = 0
        let result = try ClaudeTranscriptClassification.classify(byteLimit: Int.max) { count in
            returnedBytes += count
            return Data(repeating: 0x78, count: count)
        }

        XCTAssertEqual(result.evidence, .incomplete(.byteLimit))
        XCTAssertNil(result.client)
        XCTAssertEqual(returnedBytes, Self.maximumBytes)
        XCTAssertEqual(result.bytesRead, Self.maximumBytes)
        XCTAssertEqual(result.delimiterBytesExamined, Self.maximumBytes)
        assertLinearInspection(result)
    }

    func testNonpositiveByteLimitDoesNotReadOrDefaultToCLI() throws {
        for limit in [Int.min, -1, 0] {
            var calls = 0
            let result = try ClaudeTranscriptClassification.classify(byteLimit: limit) { _ in
                calls += 1
                return Data()
            }

            XCTAssertEqual(calls, 0)
            XCTAssertEqual(result.evidence, .incomplete(.byteLimit))
            XCTAssertNil(result.client)
            XCTAssertEqual(result.bytesRead, 0)
            XCTAssertEqual(result.delimiterBytesExamined, 0)
        }
    }

    func testRealSyntheticFileFindsDesktopEntrypointInFallback() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-session.jsonl")
        let bytes = try paddedRecord(bytes: 1_048_576, placement: .afterContent)
        let successor = Data((#"{"entrypoint":"cli"}"# + "\n").utf8)
        try (bytes + successor).write(to: source)

        let result = try ClaudeTranscriptClassification.classify(url: source)

        XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: bytes.count))
        XCTAssertEqual(result.client, .claudeDesktop)
        XCTAssertEqual(result.bytesRead, bytes.count)
        XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
        assertLinearInspection(result)
    }

    func testRealSyntheticFileKeepsCompleteJSONWithoutLFPartial() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-partial.jsonl")
        let complete = try paddedRecord(bytes: 1_048_576, placement: .afterContent)
        let bytes = Data(complete.dropLast())
        _ = try JSONSerialization.jsonObject(with: bytes)
        try bytes.write(to: source)

        let result = try ClaudeTranscriptClassification.classify(url: source)

        XCTAssertEqual(result.evidence, .incomplete(.partialRecord))
        XCTAssertNil(result.client)
        XCTAssertEqual(result.bytesRead, bytes.count)
        XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
        assertLinearInspection(result)
    }

    func testRealSyntheticFileUsesLegacyCLIAtCleanEOF() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-legacy.jsonl")
        let bytes = try paddedRecord(bytes: Self.fastPathBytes + 1, placement: .absent)
        try bytes.write(to: source)

        let result = try ClaudeTranscriptClassification.classify(url: source)

        XCTAssertEqual(result.evidence, .legacyCLI)
        XCTAssertEqual(result.client, .claudeCode)
        XCTAssertEqual(result.bytesRead, bytes.count)
        XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
        assertLinearInspection(result)
    }

    func testSourceReplacementDuringFallbackIsRejected() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-replaced.jsonl")
        let detached = root.appendingPathComponent("anonymous-detached.jsonl")
        let bytes = try paddedRecord(bytes: Self.fastPathBytes + 1, placement: .afterContent)
        try bytes.write(to: source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let replacement = Data((#"{"entrypoint":"cli"}"# + "\n").utf8)
        var readOffset = 0
        var replaced = false
        var requests: [Int] = []

        XCTAssertThrowsError(try ClaudeTranscriptClassification.classify(handle: handle, at: source) { count in
            requests.append(count)
            if readOffset == Self.fastPathBytes {
                try FileManager.default.moveItem(at: source, to: detached)
                try replacement.write(to: source)
                replaced = true
            }
            let chunk = try handle.read(upToCount: count) ?? Data()
            readOffset += chunk.count
            return chunk
        }) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ESTALE)
        }

        XCTAssertTrue(replaced)
        XCTAssertEqual(readOffset, bytes.count, "The pinned original must reach its committing LF")
        XCTAssertEqual(requests, Array(repeating: 4_096, count: 16) + [65_536])
        XCTAssertEqual(try Data(contentsOf: source), replacement)
    }

    func testSourceAppendDuringFallbackIsRejected() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-appended.jsonl")
        let bytes = try paddedRecord(bytes: Self.fastPathBytes + 1, placement: .afterContent)
        try bytes.write(to: source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        let successor = Data((#"{"entrypoint":"cli"}"# + "\n").utf8)
        var readOffset = 0
        var appended = false
        var requests: [Int] = []

        XCTAssertThrowsError(try ClaudeTranscriptClassification.classify(handle: handle, at: source) { count in
            requests.append(count)
            if readOffset == Self.fastPathBytes {
                try writer.write(contentsOf: successor)
                try writer.synchronize()
                appended = true
            }
            let chunk = try handle.read(upToCount: count) ?? Data()
            readOffset += chunk.count
            return chunk
        }) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ESTALE)
        }

        XCTAssertTrue(appended)
        XCTAssertEqual(readOffset, bytes.count + successor.count)
        XCTAssertEqual(requests, Array(repeating: 4_096, count: 16) + [65_536])
    }

    func testMismatchedPinnedSourceIsRejectedBeforeReading() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("anonymous-pre-replaced.jsonl")
        let detached = root.appendingPathComponent("anonymous-pre-detached.jsonl")
        try Data((#"{"entrypoint":"claude-desktop"}"# + "\n").utf8).write(to: source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try FileManager.default.moveItem(at: source, to: detached)
        try Data((#"{"entrypoint":"cli"}"# + "\n").utf8).write(to: source)
        var requests: [Int] = []

        XCTAssertThrowsError(try ClaudeTranscriptClassification.classify(handle: handle, at: source) { count in
            requests.append(count)
            return try handle.read(upToCount: count) ?? Data()
        }) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ESTALE)
        }

        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try handle.offset(), 0)
    }

    func testMaximumNestingDepth127RemainsExplicitForBothEntrypointOrders() throws {
        XCTAssertEqual(ClaudeTranscriptClassification.maximumNestingDepth, 127)
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            let fixture = nestingFixture(depth: 127, placement: placement)
            XCTAssertNil(fixture.firstForbiddenContainerEnd)
            _ = try JSONSerialization.jsonObject(with: fixture.bytes)
            for returnedBytes in [1, 4_096] {
                let reader = RecordingReader(fixture.bytes, maximumReturnedBytes: returnedBytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: fixture.bytes.count))
                XCTAssertEqual(result.client, .claudeDesktop)
                XCTAssertEqual(result.bytesRead, fixture.bytes.count)
                XCTAssertEqual(result.delimiterBytesExamined, fixture.bytes.count)
                assertLinearInspection(result)
            }
        }
    }

    func testNestingDepth128NeverFallsThroughToFollowingCLIRecord() throws {
        let successor = Data((#"{"entrypoint":"cli"}"# + "\n").utf8)
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            let fixture = nestingFixture(depth: 128, placement: placement)
            let forbiddenEnd = try XCTUnwrap(fixture.firstForbiddenContainerEnd)
            let bytes = fixture.bytes + successor
            XCTAssertLessThan(bytes.count, 4_096)
            for returnedBytes in [1, 4_096] {
                let reader = RecordingReader(bytes, maximumReturnedBytes: returnedBytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .incomplete(.nestingLimit))
                XCTAssertNil(result.client)
                XCTAssertEqual(result.delimiterBytesExamined, forbiddenEnd)
                XCTAssertLessThan(result.delimiterBytesExamined, fixture.bytes.count)
                XCTAssertEqual(result.bytesRead, returnedBytes == 1 ? forbiddenEnd : bytes.count)
                XCTAssertEqual(reader.offset, result.bytesRead)
                assertLinearInspection(result)
            }
        }
    }

    func testNestingDepth128WithoutLFReturnsNestingLimit() throws {
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            let fixture = nestingFixture(depth: 128, placement: placement, includesLF: false)
            let forbiddenEnd = try XCTUnwrap(fixture.firstForbiddenContainerEnd)
            for bytes in [fixture.bytes, Data(fixture.bytes.prefix(forbiddenEnd))] {
                XCTAssertFalse(bytes.contains(0x0A))
                let reader = RecordingReader(bytes, maximumReturnedBytes: 1)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .incomplete(.nestingLimit))
                XCTAssertNil(result.client)
                XCTAssertEqual(result.bytesRead, forbiddenEnd)
                XCTAssertEqual(result.delimiterBytesExamined, forbiddenEnd)
                XCTAssertEqual(reader.offset, forbiddenEnd)
                XCTAssertEqual(reader.requests.count, forbiddenEnd, "Do not read EOF after the excess container")
                assertLinearInspection(result)
            }
        }
    }

    func testQuotedBracketsAndEscapesAcrossChunksDoNotIncreaseNestingDepth() throws {
        let text = String(repeating: #"[]{} " \ \" \\ end"#, count: 256)
        let token = String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            let fixture = nestingFixture(depth: 127, placement: placement, valueToken: token)
            XCTAssertGreaterThan(fixture.bytes.count, 4_096)
            _ = try JSONSerialization.jsonObject(with: fixture.bytes)
            for returnedBytes in [1, 4_096] {
                let reader = RecordingReader(fixture.bytes, maximumReturnedBytes: returnedBytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: fixture.bytes.count))
                XCTAssertEqual(result.client, .claudeDesktop)
                XCTAssertEqual(result.bytesRead, fixture.bytes.count)
                XCTAssertEqual(result.delimiterBytesExamined, fixture.bytes.count)
                assertLinearInspection(result)
            }
        }
    }

    func testMalformedAndBlankLinesResetNestingAndStringState() throws {
        let unclosedContainers = String(repeating: "[", count: 127) + "\n\n"
        let unclosedString = "\"" + String(repeating: "{", count: 256) + "\\" + "\n\n"
        let token = String(decoding: try JSONSerialization.data(withJSONObject: String(repeating: "[", count: 256),
                                                              options: [.fragmentsAllowed]), as: UTF8.self)
        let fixture = nestingFixture(depth: 127, placement: .afterContent, valueToken: token)
        _ = try JSONSerialization.jsonObject(with: fixture.bytes)
        for prefix in [unclosedContainers, unclosedString, " \t\r\n\n", unclosedContainers + unclosedString] {
            let bytes = Data(prefix.utf8) + fixture.bytes
            for returnedBytes in [1, 4_096] {
                let reader = RecordingReader(bytes, maximumReturnedBytes: returnedBytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: bytes.count))
                XCTAssertEqual(result.client, .claudeDesktop)
                XCTAssertEqual(result.bytesRead, bytes.count)
                XCTAssertEqual(result.delimiterBytesExamined, bytes.count)
                assertLinearInspection(result)
            }
        }
    }

    private enum EntrypointPlacement {
        case beforeContent
        case afterContent
        case absent
    }

    private enum ReaderFailure: Error, Equatable {
        case injected
    }

    private struct NestingFixture {
        let bytes: Data
        let firstForbiddenContainerEnd: Int?
    }

    /// Root object is depth one. Alternating arrays and objects cover both
    /// container types; the expected violation offset comes from construction.
    private func nestingFixture(depth: Int, placement: EntrypointPlacement,
                                valueToken: String = "0", includesLF: Bool = true) -> NestingFixture {
        precondition(depth > 0)
        let start: String
        let end: String
        switch placement {
        case .beforeContent:
            start = #"{"entrypoint":"claude-desktop","content":"#
            end = "}"
        case .afterContent:
            start = #"{"content":"#
            end = #","entrypoint":"claude-desktop"}"#
        case .absent:
            start = #"{"content":"#
            end = "}"
        }
        var bytes = Data(start.utf8)
        var closingContainers: [UInt8] = []
        var firstForbiddenContainerEnd: Int?
        for level in 1..<depth {
            if level == 127 { firstForbiddenContainerEnd = bytes.count + 1 }
            if level.isMultiple(of: 2) {
                bytes.append(Data(#"{"value":"#.utf8))
                closingContainers.append(0x7D)
            } else {
                bytes.append(0x5B)
                closingContainers.append(0x5D)
            }
        }
        bytes.append(Data(valueToken.utf8))
        bytes.append(contentsOf: closingContainers.reversed())
        bytes.append(Data(end.utf8))
        if includesLF { bytes.append(0x0A) }
        return NestingFixture(bytes: bytes, firstForbiddenContainerEnd: firstForbiddenContainerEnd)
    }

    private final class RecordingReader {
        private let bytes: Data
        private let maximumReturnedBytes: Int
        private(set) var offset = 0
        private(set) var requests: [Int] = []

        init(_ bytes: Data, maximumReturnedBytes: Int = Int.max) {
            self.bytes = bytes
            self.maximumReturnedBytes = maximumReturnedBytes
        }

        func read(_ requested: Int) -> Data {
            precondition(requested > 0 && maximumReturnedBytes > 0)
            requests.append(requested)
            let count = min(requested, min(bytes.count - offset, maximumReturnedBytes))
            defer { offset += count }
            return bytes.subdata(in: offset..<(offset + count))
        }
    }

    /// Each target size includes LF; padding is inside valid JSON string content.
    /// Keep the two field orders sequential so the largest fixtures are released.
    private func assertExplicitRecord(bytes count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        for placement in [EntrypointPlacement.beforeContent, .afterContent] {
            try autoreleasepool {
                let bytes = try paddedRecord(bytes: count, placement: placement)
                let reader = RecordingReader(bytes)

                let result = try ClaudeTranscriptClassification.classify(read: reader.read)

                XCTAssertEqual(result.evidence, .explicit(client: .claudeDesktop, recordEnd: count), file: file, line: line)
                XCTAssertEqual(result.client, .claudeDesktop, file: file, line: line)
                XCTAssertEqual(result.bytesRead, count, file: file, line: line)
                XCTAssertEqual(result.delimiterBytesExamined, count, file: file, line: line)
                XCTAssertEqual(reader.offset, count, file: file, line: line)
                XCTAssertEqual(Array(reader.requests.prefix(16)), Array(repeating: 4_096, count: 16), file: file, line: line)
                if count > Self.fastPathBytes {
                    XCTAssertEqual(reader.requests.dropFirst(16).first, 65_536, file: file, line: line)
                } else {
                    XCTAssertEqual(reader.requests.count, 16, file: file, line: line)
                }
                assertLinearInspection(result, file: file, line: line)
            }
        }
    }

    private func paddedRecord(bytes target: Int, placement: EntrypointPlacement) throws -> Data {
        let start: String
        let end: String
        switch placement {
        case .beforeContent:
            start = #"{"type":"assistant","entrypoint":"claude-desktop","message":{"content":""#
            end = #""}}"# + "\n"
        case .afterContent:
            start = #"{"type":"assistant","message":{"content":""#
            end = #""},"entrypoint":"claude-desktop"}"# + "\n"
        case .absent:
            start = #"{"type":"assistant","message":{"content":""#
            end = #""}}"# + "\n"
        }
        let overhead = start.utf8.count + end.utf8.count
        guard target >= overhead else {
            throw CocoaError(.coderInvalidValue)
        }
        var bytes = Data(start.utf8)
        bytes.append(Data(repeating: 0x78, count: target - overhead))
        bytes.append(Data(end.utf8))
        XCTAssertEqual(bytes.count, target)
        XCTAssertEqual(bytes.last, 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        switch placement {
        case .beforeContent, .afterContent:
            XCTAssertEqual(object["entrypoint"] as? String, "claude-desktop")
        case .absent:
            XCTAssertNil(object["entrypoint"])
        }
        return bytes
    }

    private func assertLinearInspection(_ result: ClaudeTranscriptClassification.Result,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(result.delimiterBytesExamined, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(result.delimiterBytesExamined, result.bytesRead, file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-transcript-classification-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
