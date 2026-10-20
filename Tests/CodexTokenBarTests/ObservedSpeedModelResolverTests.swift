import XCTest
@testable import CodexTokenBar

final class ObservedSpeedModelResolverTests: XCTestCase {
    func context(_ turn: String, _ model: String) -> String {
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(turn)\",\"model\":\"\(model)\"}}\n"
    }
    func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testFindsExactTurnInContinuationAndReadsAppendsWithoutBorrowingCurrentModel() async throws {
        let home = try temporaryHome()
        let original = home.appendingPathComponent("sessions/rollout-thread.jsonl")
        let fork = home.appendingPathComponent("sessions/rollout-thread_continuation.jsonl")
        try context("old", "old-model").write(to: original, atomically: true, encoding: .utf8)
        try context("new", "new-model").write(to: fork, atomically: true, encoding: .utf8)
        let resolver = ObservedSpeedModelResolver()
        let wanted = ["thread": Set(["old", "new", "missing"])]
        let result = await resolver.resolve(home: home, paths: ["thread": original.path], requested: wanted)
        XCTAssertEqual(result["thread"], ["old": "old-model", "new": "new-model"])
        let handle = try FileHandle(forWritingTo: fork)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(context("next", "next-model").utf8)); try handle.close()
        let updated = await resolver.resolve(home: home, paths: [:], requested: ["thread": ["next"]])
        XCTAssertEqual(updated["thread"]?["next"], "next-model")
    }
    func testConflictingPhysicalContextsDoNotChooseAModelArbitrarily() async throws {
        let home = try temporaryHome()
        for (name, model) in [("rollout-thread-a.jsonl", "a"), ("rollout-thread-b.jsonl", "b")] {
            try context("same", model).write(to: home.appendingPathComponent("sessions/\(name)"), atomically: true, encoding: .utf8)
        }
        let result = await ObservedSpeedModelResolver().resolve(home: home, paths: [:], requested: ["thread": ["same"]])
        XCTAssertNil(result["thread"]?["same"])
    }
    func testOversizedToolLineAndTruncatedFileDoNotLeakTextOrStaleModel() async throws {
        let home = try temporaryHome(), path = home.appendingPathComponent("sessions/rollout-thread.jsonl")
        try (String(repeating: "x", count: 1_200_000) + "\n" + context("turn", "model")).write(to: path, atomically: false, encoding: .utf8)
        let resolver = ObservedSpeedModelResolver()
        let result = await resolver.resolve(home: home, paths: [:], requested: ["thread": ["turn"]])
        XCTAssertEqual(result["thread"]?["turn"], "model")
        try context("replacement", "new").write(to: path, atomically: false, encoding: .utf8)
        let changed = await resolver.resolve(home: home, paths: [:], requested: ["thread": ["turn", "replacement"]])
        XCTAssertEqual(changed["thread"], ["replacement": "new"])
    }
}
