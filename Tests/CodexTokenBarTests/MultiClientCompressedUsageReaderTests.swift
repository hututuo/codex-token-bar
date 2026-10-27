import XCTest
@testable import CodexTokenBar

final class MultiClientCompressedUsageReaderTests: XCTestCase {
    private func frame(_ text: String) throws -> Data {
        // A standard Zstandard frame with one uncompressed final block; no encoder dependency.
        let bytes = Array(text.utf8)
        precondition(bytes.count < 128 * 1024)
        let header = UInt32(bytes.count << 3) | 1
        return Data([0x28, 0xb5, 0x2f, 0xfd, 0, 0x58,
                     UInt8(header & 255), UInt8((header >> 8) & 255), UInt8((header >> 16) & 255)] + bytes)
    }
    func testCompleteFramesCommitBeforeAnIncompleteTail() throws {
        let first = try frame("{\"a\":1}\n"), second = try frame("{\"b\":2}\n")
        let batch = try MultiClientCompressedUsageReader.decode(first + second.dropLast(2))
        XCTAssertEqual(batch.consumed, first.count)
        XCTAssertEqual(String(decoding: batch.data, as: UTF8.self), "{\"a\":1}\n")
        let full = try MultiClientCompressedUsageReader.decode(first + second)
        XCTAssertEqual(full.consumed, first.count + second.count)
    }
    func testSplitLineAcrossFramesDoesNotCheckpointUntilComplete() throws {
        let first = try frame("{\"a\":"), second = try frame("1}\n")
        XCTAssertEqual(try MultiClientCompressedUsageReader.decode(first).consumed, 0)
        let result = try MultiClientCompressedUsageReader.decode(first + second)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "{\"a\":1}\n")
    }
    func testScannerFindsCompressedHarnessAndRetainsLedgerAfterRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-compressed-" + UUID().uuidString)
        let directory = root.appendingPathComponent(".dsh/sessions/sample")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("session.v4.jsonl.zstd")
        let line = #"{"type":"event","event":{"type":"assistant/message","time":1797000000000,"seq":9,"data":{"message":{"id":"m1","source":{"model":"deepseek-v4"}},"usage":{"inputTokens":100,"outputTokens":12,"cacheReadTokens":4,"cacheWriteTokens":2}}}}"# + "\n"
        let bytes = try frame(line); try bytes.write(to: url)
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        var preference = MultiClientUsagePreference.defaults.first { $0.client == .deepseek }!
        preference.enabled = true
        let first = try await scanner.scan([preference])
        XCTAssertEqual(first.summaries.first?.inputTokens, 106)
        XCTAssertEqual(first.summaries.first?.outputTokens, 12)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let replay = try await scanner.scan([preference])
        XCTAssertEqual(replay.summaries.first?.requests, 1)
        try FileManager.default.removeItem(at: url)
        let removed = try await scanner.scan([preference])
        XCTAssertEqual(removed.summaries.first?.outputTokens, 12)
    }
    func testDeepSeekIdentitySurvivesAppendRestartAndSeparateDirectories() async throws {
        for compressed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-identity-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent(".dsh/sessions/directory-a")
            let otherDirectory = root.appendingPathComponent(".dsh/sessions/directory-b")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            let name = compressed ? "session.v4.jsonl.zstd" : "session.v4.jsonl"
            let url = directory.appendingPathComponent(name)
            let event = #"{"type":"assistant/message","seq":9,"time":1797000000000,"data":{"message":{"id":"m1","source":{"model":"deepseek-v4"}},"usage":{"inputTokens":100,"outputTokens":12}}}"#
            let snapshot = #"{"type":"snapshot","header":{"id":"native-a"},"records":["# + event + "]}\n"
            func encoded(_ text: String) throws -> Data { compressed ? try frame(text) : Data(text.utf8) }
            var bytes = try encoded(snapshot)
            try bytes.write(to: url)
            let database = root.appendingPathComponent("usage.sqlite")
            var preference = MultiClientUsagePreference.defaults.first { $0.client == .deepseek }!
            preference.enabled = true
            let scanner = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
            let initial = try await scanner.scan([preference])
            XCTAssertEqual(initial.summaries.first?.requests, 1)
            bytes += try encoded(event + "\n") // Same request repeated outside its snapshot.
            try bytes.write(to: url)
            let appended = try await scanner.scan([preference])
            XCTAssertEqual(appended.summaries.first?.requests, 1)
            let restarted = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
            bytes += try encoded(event.replacingOccurrences(of: "m1", with: "m2") + "\n")
            try bytes.write(to: url)
            let afterRestart = try await restarted.scan([preference])
            XCTAssertEqual(afterRestart.summaries.first?.requests, 2)
            // A headerless second session with the same version filename and message ID must not collide.
            try encoded(event + "\n").write(to: otherDirectory.appendingPathComponent(name))
            let separated = try await restarted.scan([preference])
            XCTAssertEqual(separated.summaries.first?.requests, 3)
            XCTAssertEqual(separated.summaries.first?.outputTokens, 36)
        }
    }

    func testDecodedSizeAndCorruptionAreBounded() throws {
        XCTAssertThrowsError(try MultiClientCompressedUsageReader.decode(frame(String(repeating: "x", count: 1000) + "\n"), maximumDecoded: 100))
        XCTAssertThrowsError(try MultiClientCompressedUsageReader.decode(Data("not a zstd stream".utf8)))
    }
}
