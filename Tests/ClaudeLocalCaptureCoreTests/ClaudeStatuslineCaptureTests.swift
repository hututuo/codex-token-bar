import Darwin
import Foundation
import XCTest
@testable import ClaudeLocalCaptureCore

final class ClaudeStatuslineCaptureTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let resolvedRootPath: String? = FileManager.default.temporaryDirectory.path.withCString { path -> String? in
            guard let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        let resolvedRoot = try XCTUnwrap(resolvedRootPath)
        let directory = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
            .appendingPathComponent("claude-local-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func snapshot(
        sessionId: String = "session-123",
        capturedAt: Int64 = 1_800_000_000
    ) -> ClaudeStatuslineSnapshot {
        ClaudeStatuslineSnapshot(
            capturedAtEpoch: capturedAt,
            sessionId: sessionId,
            model: .init(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6"),
            rateLimits: .init(
                fiveHour: .init(usedPercentage: 25, resetsAt: 1_800_003_600),
                sevenDay: .init(usedPercentage: 10, resetsAt: 1_802_000_000),
                spendLimit: nil
            ),
            cost: .init(totalAPIDurationMS: 12_000, totalDurationMS: 48_000),
            contextWindow: .init(
                contextWindowSize: 200_000,
                totalInputTokens: 33_000,
                totalOutputTokens: 9_000,
                currentUsage: .init(
                    inputTokens: 4_000,
                    outputTokens: 600,
                    cacheCreationInputTokens: 400,
                    cacheReadInputTokens: 3_000
                )
            )
        )
    }

    func testParserRetainsOnlyWhitelistedFields() throws {
        let input = Data(#"""
        {
          "session_id":"session-123",
          "model":{"id":"claude-sonnet-4-6","display_name":"Sonnet 4.6","secret":"drop me"},
          "rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1800003600},"seven_day":{"used_percentage":10,"resets_at":1802000000},"unknown":{"secret":"drop me"}},
          "cost":{"total_api_duration_ms":12000,"total_duration_ms":48000,"total_cost_usd":9.75},
          "context_window":{"context_window_size":200000,"total_input_tokens":33000,"total_output_tokens":9000,"current_usage":{"input_tokens":4000,"output_tokens":600,"cache_creation_input_tokens":400,"cache_read_input_tokens":3000,"secret":"drop me"},"used_percentage":90},
          "cwd":"/private/path/project",
          "transcript_path":"/private/path/session.jsonl",
          "prompt":"private prompt text",
          "tool_result":"private tool result",
          "credential":"bearer private-token"
        }
        """#.utf8)

        let parsed = try ClaudeStatuslineParser.parse(input, capturedAt: Date(timeIntervalSince1970: 1_800_000_001.9))
        XCTAssertEqual(parsed, snapshot(capturedAt: 1_800_000_001))

        let encoded = try JSONEncoder().encode(parsed)
        let output = String(decoding: encoded, as: UTF8.self)
        for forbidden in [
            "private/path",
            "private prompt text",
            "private tool result",
            "bearer private-token",
            "total_cost_usd",
            "secret",
            "used_percentage\":90"
        ] {
            XCTAssertFalse(output.contains(forbidden), "Unexpected retained input: \(forbidden)")
        }
    }

    func testParserRejectsMalformedOversizedAndInvalidNumericInput() {
        XCTAssertThrowsError(try ClaudeStatuslineParser.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try ClaudeStatuslineParser.parse(Data(repeating: 0x20, count: ClaudeStatuslineParser.maximumInputBytes + 1))) { error in
            XCTAssertEqual(error as? ClaudeStatuslineCaptureError, .inputTooLarge)
        }

        for invalid in [
            #"{"context_window":{"total_input_tokens":-1}}"#,
            #"{"context_window":{"total_output_tokens":true}}"#,
            #"{"cost":{"total_api_duration_ms":1.5}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":-1}}}"#,
            #"{"model":{"display_name":"line\nbreak"}}"#
        ] {
            XCTAssertThrowsError(try ClaudeStatuslineParser.parse(Data(invalid.utf8)), invalid)
        }
    }

    func testParserAllowsOverQuotaPercentagesAndDropsEmptyWhitelistedObjects() throws {
        let parsed = try ClaudeStatuslineParser.parse(
            Data(#"{"model":{"ignored":"value"},"rate_limits":{"five_hour":{},"seven_day":{"used_percentage":125}}}"#.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNil(parsed.model)
        XCTAssertNil(parsed.rateLimits?.fiveHour)
        XCTAssertEqual(parsed.rateLimits?.sevenDay?.usedPercentage, 125)
    }

    func testParserNormalizesNumericAndISO8601ResetTimesToEpochSeconds() throws {
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":"2027-01-15T09:00:00Z"},"seven_day":{"used_percentage":10,"resets_at":1802000000}}}"#.utf8)
        let parsed = try ClaudeStatuslineParser.parse(input, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(parsed.rateLimits?.fiveHour?.resetsAt, 1_800_003_600)
        XCTAssertEqual(parsed.rateLimits?.sevenDay?.resetsAt, 1_802_000_000)
    }

    func testWriterUsesHashedSessionNameAndPrivateAtomicCacheFiles() throws {
        let applicationSupport = try temporaryDirectory().appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let writer = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: applicationSupport)
        let value = snapshot()

        try writer.write(value)

        let expectedName = ClaudeStatuslineSnapshotWriter.sessionFilename(for: "session-123")
        XCTAssertTrue(expectedName.range(of: #"^session-[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil)
        XCTAssertFalse(expectedName.contains("session-123"))
        let sessionFile = writer.cacheDirectory.appendingPathComponent(expectedName)
        let latestFile = writer.cacheDirectory.appendingPathComponent("latest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestFile.path))

        let encoded = try Data(contentsOf: latestFile)
        let output = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(output.contains("\"schema_version\":1"))
        XCTAssertTrue(output.contains("\"session_id\":\"session-123\""))
        XCTAssertFalse(output.contains("transcript_path"))
        XCTAssertFalse(output.contains("prompt"))
        XCTAssertFalse(output.contains("credential"))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: writer.cacheDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: latestFile.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWriterRejectsSymlinkedCacheParentAndTarget() throws {
        let applicationSupport = try temporaryDirectory().appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let outside = try temporaryDirectory()

        let linkedSupport = applicationSupport.deletingLastPathComponent().appendingPathComponent("linked-support", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSupport, withDestinationURL: applicationSupport)
        let supportPathWriter = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: linkedSupport)
        XCTAssertThrowsError(try supportPathWriter.write(snapshot()))

        let appDirectory = applicationSupport.appendingPathComponent("CodexTokenBar", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: appDirectory, withDestinationURL: outside)

        let parentWriter = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: applicationSupport)
        XCTAssertThrowsError(try parentWriter.write(snapshot()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("claude-local-statusline").path))

        let cleanSupport = try temporaryDirectory().appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanSupport, withIntermediateDirectories: true)
        let writer = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: cleanSupport)
        try writer.write(snapshot())
        let outsideTarget = outside.appendingPathComponent("sentinel.json")
        let sentinel = Data("leave untouched".utf8)
        try sentinel.write(to: outsideTarget)

        let latest = writer.cacheDirectory.appendingPathComponent("latest.json")
        try FileManager.default.removeItem(at: latest)
        try FileManager.default.createSymbolicLink(at: latest, withDestinationURL: outsideTarget)
        XCTAssertThrowsError(try writer.write(snapshot(capturedAt: 1_800_000_001)))
        XCTAssertEqual(try Data(contentsOf: outsideTarget), sentinel)
    }

    func testWriterKeepsAtMost64SessionFilesAndRetainsNewest() throws {
        let applicationSupport = try temporaryDirectory().appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let writer = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: applicationSupport)

        for index in 0..<65 {
            try writer.write(snapshot(sessionId: "session-\(index)", capturedAt: 1_800_000_000 + Int64(index)))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: writer.cacheDirectory.path)
        let sessionFiles = files.filter { $0.range(of: #"^session-[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil }
        XCTAssertEqual(sessionFiles.count, 64)
        XCTAssertTrue(sessionFiles.contains(ClaudeStatuslineSnapshotWriter.sessionFilename(for: "session-64")))
        XCTAssertTrue(files.contains("latest.json"))
        let latestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: writer.cacheDirectory.appendingPathComponent("latest.json"))) as? [String: Any]
        )
        XCTAssertEqual(latestObject["session_id"] as? String, "session-64")
    }

    func testMissingSessionIDWritesOnlyLatestSnapshot() throws {
        let applicationSupport = try temporaryDirectory().appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let writer = ClaudeStatuslineSnapshotWriter(applicationSupportDirectory: applicationSupport)
        let noSession = ClaudeStatuslineSnapshot(
            capturedAtEpoch: 1_800_000_000,
            sessionId: nil,
            model: nil,
            rateLimits: nil,
            cost: nil,
            contextWindow: nil
        )

        try writer.write(noSession)

        let files = try FileManager.default.contentsOfDirectory(atPath: writer.cacheDirectory.path)
        XCTAssertEqual(files, ["latest.json"])
    }
}
