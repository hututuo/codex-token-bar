import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class CacheRetentionStoreTests: XCTestCase {
    func testScopeRestorationSurvivesBackgroundLifecycleCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = UUID().uuidString, first = UUID().uuidString, second = UUID().uuidString
        let start = Int(Date().timeIntervalSince1970) - 1_000
        var rows: [[String: Any]] = [["type": "session_meta", "payload": ["id": session]]]
        for (index, id) in [first, second].enumerated() {
            let at = start + index * 30
            rows += [
                ["type": "event_msg", "timestamp": at, "payload": ["type": "task_started", "turn_id": id, "started_at": at]],
                ["type": "event_msg", "timestamp": at + 1, "payload": ["type": "user_message"]],
                ["type": "turn_context", "timestamp": at + 2, "payload": ["turn_id": id, "model": "model-a"]],
                ["type": "event_msg", "timestamp": at + 3, "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 100, "cached_input_tokens": 90]]]],
                ["type": "event_msg", "timestamp": at + 10, "payload": ["type": "task_complete", "turn_id": id, "completed_at": at + 10]]
            ]
        }
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: sessions.appendingPathComponent("rollout-\(session).jsonl"))
        let db = root.appendingPathComponent("diagnostic.sqlite")
        let store = CacheRetentionStore(engineFactory: { try CacheRetentionEngine(source: $0, databaseURL: db) })
        store.bind(.init(codexHome: home, origin: .userSelected))
        store.refresh()
        try await eventually { !store.isUpdating && store.snapshot.points.count == 1 }
        store.select(model: .some("no-matches"))
        try await eventually { store.snapshot.updatedAt != nil && store.snapshot.points.isEmpty }
        store.select(range: .all, model: .some(nil))
        store.cancelBackgroundWork()
        try await eventually { store.snapshot.points.count == 1 }
        XCTAssertNil(store.scope.model)
        XCTAssertEqual(store.chart.points.count, 1)
        XCTAssertEqual(store.adviceAnalysis.count, 1)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The selected snapshot did not finish")
    }
}
