import Foundation
import XCTest
@testable import AgentSpeedCore

final class ActivityEngineParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Response: Decodable { let id, agent, source: String; let model: String?; let start, end: Int64; let input, output: Int; let final: Bool? }
        struct Agent: Decodable { let id, source: String; let model: String?; let start, last: Int64 }
        struct Expected: Decodable { let source: String; let model: String?; let output, total: Double }
        let name: String; let now: Int64; let responses: [Response]; let agents: [Agent]; let expected: [Expected]
    }
    func testSharedEngineContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/activity-model-attribution.json")))
        let epoch: Int64 = 1_800_000_000_000
        for fixture in fixtures {
            var engine = SpeedEngine()
            for row in fixture.responses {
                engine.upsert(ResponseRecord(key: row.id, source: try source(row.source), agentId: row.agent, model: row.model,
                    startMs: epoch + row.start, endMs: epoch + row.end, usage: .init(input: row.input, output: row.output), isFinal: row.final ?? true),
                    project: "fixture", isCompletion: true, emitsEvents: false)
            }
            for row in fixture.agents {
                engine.setAgent(.init(id: row.id, source: try source(row.source), project: "fixture", model: row.model,
                    phase: .generating, inFlightStartMs: epoch + row.start, lastLineMs: epoch + row.last))
            }
            let frame = engine.advance(nowMs: epoch + fixture.now, todayStartMs: epoch, emitsEvents: false)
            XCTAssertEqual(frame.liveModels.count, fixture.expected.count, fixture.name)
            for row in fixture.expected {
                let kind = try source(row.source)
                let actual = try XCTUnwrap(frame.liveModels.first { $0.source == kind && $0.model == row.model }, fixture.name)
                XCTAssertEqual(actual.rate.output, row.output, accuracy: 1e-8, fixture.name)
                XCTAssertEqual(actual.rate.total, row.total, accuracy: 1e-8, fixture.name)
            }
            XCTAssertEqual(frame.liveModels.reduce(0) { $0 + $1.rate.output }, frame.live.output, accuracy: 1e-8)
            XCTAssertEqual(frame.liveModels.reduce(0) { $0 + $1.rate.total }, frame.live.total, accuracy: 1e-8)
        }
    }
    private func source(_ raw: String) throws -> SourceKind {
        try XCTUnwrap(SourceKind(rawValue: raw))
    }
}
