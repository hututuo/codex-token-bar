import CryptoKit
import Foundation
import XCTest
@testable import CodexTokenBar

final class ClaudeRecordBoundaryTests: XCTestCase {
    private static let readWindowBytes = 4 * 1_024 * 1_024

    private enum ContentShape: CaseIterable {
        case plainText
        case structuredToolResult
    }

    func testHistoryScannerAccepts64KiBRecordAndShortSuccessor() async throws {
        try await assertAcceptedRecord(recordBytes: 64 * 1_024)
    }

    func testHistoryScannerAccepts1MiBRecordAndShortSuccessor() async throws {
        try await assertAcceptedRecord(recordBytes: 1_024 * 1_024)
    }

    func testHistoryScannerAcceptsExactly4MiBRecordAndShortSuccessorAcrossScans() async throws {
        try await assertAcceptedRecord(recordBytes: Self.readWindowBytes)
    }

    func testHistoryScannerRejects4MiBPlusOneWithoutCheckpointOrSuccessorUsage() async throws {
        for shape in ContentShape.allCases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("session.jsonl")
            let large = try record(id: "large", seed: 1, bytes: Self.readWindowBytes + 1, shape: shape)
            let after = try record(id: "after", seed: 2)
            try (large + after).write(to: source)
            let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
            let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: root, environment: [:])
            let preference = try preference(for: source)

            for _ in 0..<3 {
                let result = try await scanner.scan([preference], includesCharts: false)
                assertOversizedDiagnostic(result)
                XCTAssertTrue(result.summaries.isEmpty)
                XCTAssertTrue(try events(in: ledger).isEmpty)
                XCTAssertEqual(try revisionCount(in: ledger), 0)
                XCTAssertNil(try ledger.checkpoint(client: .claudeCode, sourceKey: sourceKey(source)))
            }
        }
    }

    func testHistoryScannerPreservesCommittedPrefixAndResumesAfterSameFileRepair() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("session.jsonl")
        let prefix = try record(id: "prefix", seed: 3)
        let oversized = try record(id: "large", seed: 1, bytes: Self.readWindowBytes + 1,
                                   shape: .structuredToolResult)
        let after = try record(id: "after", seed: 2)
        let original = prefix + oversized + after
        try original.write(to: source)
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: root, environment: [:])
        let preference = try preference(for: source)

        // The first window contains one LF: only that complete prefix commits.
        let first = try await scanner.scan([preference], includesCharts: false)
        XCTAssertTrue(first.diagnostics.isEmpty)
        try assertEvents(in: ledger, seeds: [3])
        let committed = try assertCheckpoint(in: ledger, source: source, offset: prefix.count)
        XCTAssertEqual(committed.size, Int64(original.count))
        for _ in 0..<2 {
            let blocked = try await scanner.scan([preference], includesCharts: false)
            assertOversizedDiagnostic(blocked)
            try assertEvents(in: ledger, seeds: [3])
            let unchanged = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: sourceKey(source)))
            assertSameCheckpoint(unchanged, committed)
            XCTAssertEqual(try revisionCount(in: ledger), 1)
        }

        // Preserve the covered prefix and inode, but shorten the rest. The existing
        // identity rule keeps that prefix valid, and the changed size permits resume.
        let repaired = prefix + (try record(id: "large", seed: 1, bytes: 64 * 1_024,
                                            shape: .structuredToolResult)) + after
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: repaired)
        let repairedAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual(String(describing: repairedAttributes[.systemFileNumber] ?? ""),
                       String(describing: originalAttributes[.systemFileNumber] ?? ""))
        XCTAssertNotEqual(repaired.count, original.count)
        XCTAssertEqual(Data(repaired.prefix(prefix.count)), prefix)

        let resumed = try await scanner.scan([preference], includesCharts: false)
        XCTAssertTrue(resumed.diagnostics.isEmpty)
        try assertEvents(in: ledger, seeds: [1, 2, 3])
        _ = try assertCheckpoint(in: ledger, source: source, offset: repaired.count)
        XCTAssertEqual(try revisionCount(in: ledger), 3)
        let idle = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(idle.summaries, resumed.summaries)
        XCTAssertTrue(idle.diagnostics.isEmpty)
        XCTAssertEqual(try revisionCount(in: ledger), 3)
    }

    private func assertAcceptedRecord(recordBytes: Int) async throws {
        for shape in ContentShape.allCases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("session.jsonl")
            let large = try record(id: "large", seed: 1, bytes: recordBytes, shape: shape)
            let after = try record(id: "after", seed: 2)
            let contents = large + after
            try contents.write(to: source)
            let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
            let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: root, environment: [:])
            let preference = try preference(for: source)

            let first = try await scanner.scan([preference], includesCharts: false)
            XCTAssertTrue(first.diagnostics.isEmpty)
            let firstOffset = recordBytes == Self.readWindowBytes ? large.count : contents.count
            _ = try assertCheckpoint(in: ledger, source: source, offset: firstOffset)
            try assertEvents(in: ledger, seeds: recordBytes == Self.readWindowBytes ? [1] : [1, 2])
            let completed = try await scanner.scan([preference], includesCharts: false)
            XCTAssertTrue(completed.diagnostics.isEmpty)
            XCTAssertEqual(completed.summaries.reduce(0) { $0 + $1.requests }, 2)
            try assertEvents(in: ledger, seeds: [1, 2])
            _ = try assertCheckpoint(in: ledger, source: source, offset: contents.count)
            XCTAssertEqual(try revisionCount(in: ledger), 2)

            // A same-size mtime change deliberately replays from zero under the
            // existing scanner rule. Revisions and normalized usage stay idempotent.
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(60)],
                                                 ofItemAtPath: source.path)
            for _ in 0..<2 {
                let replayed = try await scanner.scan([preference], includesCharts: false)
                XCTAssertTrue(replayed.diagnostics.isEmpty)
                try assertEvents(in: ledger, seeds: [1, 2])
                XCTAssertEqual(try revisionCount(in: ledger), 2)
            }
            _ = try assertCheckpoint(in: ledger, source: source, offset: contents.count)
        }
    }

    /// Every size includes its LF. Padding lives inside anonymous JSON content,
    /// never trailing whitespace; usage comes after the large value in wire order.
    private func record(id: String, seed: Int, bytes: Int? = nil,
                        shape: ContentShape = .plainText) throws -> Data {
        let contentStart: String
        let contentEnd: String
        switch shape {
        case .plainText:
            contentStart = "\""
            contentEnd = "\""
        case .structuredToolResult:
            contentStart = #"[{"type":"tool_result","tool_use_id":"anonymous-tool","content":[{"type":"text","text":"escaped: \" \\ \n \u263a "#
            contentEnd = #""}]},{"type":"text","text":"anonymous suffix"}]"#
        }
        let start = #"{"type":"assistant","entrypoint":"cli","sessionId":"anonymous-session","timestamp":"2026-11-26T10:00:0\#(seed)Z","message":{"id":"\#(id)","model":"claude-opus","content":\#(contentStart)"#
        let end = #"\#(contentEnd),"stop_reason":"end_turn","usage":{"input_tokens":\#(7 * seed),"output_tokens":\#(19 * seed),"cache_read_input_tokens":\#(11 * seed),"cache_creation_input_tokens":\#(13 * seed),"cache_creation":{"ephemeral_5m_input_tokens":\#(5 * seed),"ephemeral_1h_input_tokens":\#(8 * seed)},"output_tokens_details":{"thinking_tokens":\#(3 * seed)}}}}"# + "\n"
        let overhead = start.utf8.count + end.utf8.count
        let target = bytes ?? overhead + 16
        XCTAssertGreaterThanOrEqual(target, overhead)
        var result = Data(start.utf8)
        result.append(Data(repeating: 0x61, count: max(0, target - overhead)))
        result.append(Data(end.utf8))
        XCTAssertEqual(result.count, target)
        // Validate the synthetic fixture independently of the usage parser.
        _ = try JSONSerialization.jsonObject(with: result)
        return result
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-record-boundary-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func preference(for source: URL) throws -> MultiClientUsagePreference {
        var value = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
        value.enabled = true
        value.path = source.path
        return value
    }

    private func sourceKey(_ source: URL) -> String {
        SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func events(in ledger: MultiClientUsageLedger) throws -> [ClientUsageEvent] {
        let payloads = try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY output_tokens") {
            $0.text(0) ?? ""
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try payloads.map { try decoder.decode(ClientUsageEvent.self, from: Data($0.utf8)) }
    }

    private func assertEvents(in ledger: MultiClientUsageLedger, seeds: [Int]) throws {
        let stored = try events(in: ledger)
        XCTAssertEqual(stored.count, seeds.count)
        XCTAssertEqual(Set(stored.map(\.eventID)).count, seeds.count)
        for (event, seed) in zip(stored, seeds.sorted()) {
            XCTAssertEqual(event.client, .claudeCode)
            XCTAssertEqual(event.sessionID, "anonymous-session")
            XCTAssertEqual(event.model, "claude-opus")
            XCTAssertEqual(event.inputTokens, Int64(31 * seed))
            XCTAssertEqual(event.outputTokens, Int64(19 * seed))
            XCTAssertEqual(event.cacheReadTokens, Int64(11 * seed))
            XCTAssertEqual(event.cacheWriteTokens, Int64(13 * seed))
            XCTAssertEqual(event.cacheWrite5mTokens, Int64(5 * seed))
            XCTAssertEqual(event.cacheWrite1hTokens, Int64(8 * seed))
            XCTAssertEqual(event.reasoningTokens, Int64(3 * seed))
            XCTAssertEqual(event.quality, "recorded")
        }
    }

    @discardableResult
    private func assertCheckpoint(in ledger: MultiClientUsageLedger, source: URL,
                                  offset: Int) throws -> MultiClientFileCheckpoint {
        let saved = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: sourceKey(source)))
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970
        let width = min(4_096, offset)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: width) ?? Data()
        let digest = SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
        let rawIdentity = String(describing: attributes[.systemFileNumber] ?? "") + ":\(width):" + digest
        XCTAssertEqual(saved.offset, Int64(offset))
        XCTAssertEqual(saved.size, size)
        XCTAssertEqual(saved.modified, modified)
        XCTAssertEqual(saved.identity, "claude-cache-lifetimes-v1|" + rawIdentity)
        return saved
    }

    private func assertSameCheckpoint(_ actual: MultiClientFileCheckpoint, _ expected: MultiClientFileCheckpoint) {
        XCTAssertEqual(actual.offset, expected.offset)
        XCTAssertEqual(actual.size, expected.size)
        XCTAssertEqual(actual.modified, expected.modified)
        XCTAssertEqual(actual.identity, expected.identity)
    }

    private func revisionCount(in ledger: MultiClientUsageLedger) throws -> Int64 {
        try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first ?? 0
    }

    private func assertOversizedDiagnostic(_ result: MultiClientScanResult) {
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics.contains {
            $0.contains("已保留旧账") && $0.contains("单条或单文件超过读取上限，未跳过其断点")
        })
    }
}
