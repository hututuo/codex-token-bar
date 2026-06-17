import Foundation
import XCTest
@testable import CodexTokenBar

final class RecentRateLimitDetectorTests: XCTestCase {
    func testLatestLimitIDUsesNewestTokenCountEventAcrossRecentSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentRateLimitDetectorTests-\(UUID().uuidString)", isDirectory: true)
        let sessionRoot = root.appendingPathComponent("sessions/2026/06/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = sessionRoot.appendingPathComponent("older.jsonl")
        let newer = sessionRoot.appendingPathComponent("newer.jsonl")
        try writeSession(
            to: older,
            timestamp: "2026-06-18T01:00:00.000Z",
            limitID: "codex"
        )
        try writeSession(
            to: newer,
            timestamp: "2026-06-18T02:00:00.000Z",
            limitID: "codex_bengalfox"
        )

        XCTAssertEqual(
            RecentRateLimitDetector.latestLimitID(codexHome: root, fileLimit: 8, tailBytes: 64 * 1024),
            "codex_bengalfox"
        )
    }

    func testLatestLimitIDIgnoresNonTokenCountLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentRateLimitDetectorTests-\(UUID().uuidString)", isDirectory: true)
        let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = sessionRoot.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"timestamp":"2026-06-18T01:00:00.000Z","type":"event_msg","payload":{"type":"agent_message","rate_limits":{"limit_id":"wrong"}}}"#,
            tokenCountLine(timestamp: "2026-06-18T01:01:00.000Z", limitID: "codex_bengalfox")
        ]
        try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)

        XCTAssertEqual(RecentRateLimitDetector.latestLimitID(codexHome: root), "codex_bengalfox")
    }

    private func writeSession(to url: URL, timestamp: String, limitID: String) throws {
        let lines = [
            #"{"timestamp":"2026-06-18T00:00:00.000Z","type":"session_meta","payload":{"id":"test"}}"#,
            tokenCountLine(timestamp: timestamp, limitID: limitID)
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func tokenCountLine(timestamp: String, limitID: String) -> String {
        #"{"timestamp":""# + timestamp + #"","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":""# + limitID + #"","primary":{"used_percent":0.0,"resets_at":1781734836},"secondary":{"used_percent":0.0,"resets_at":1782321636}}}}"#
    }
}
