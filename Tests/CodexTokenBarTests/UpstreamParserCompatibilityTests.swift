import Foundation
import XCTest
@testable import AgentSpeedCore

final class UpstreamParserCompatibilityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expected: Decodable {
            let output, responseCount: Int
            let phase: String
            let model: String?
            let stopped: Bool
        }
        let name, family: String
        let lines: [String]
        let expected: Expected
    }

    func testSharedCompatibilityCases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/upstream-parser-compat.json")))
        XCTAssertEqual(fixtures.count, 25)
        for fixture in fixtures {
            let family = try XCTUnwrap(TranscriptFamily(rawValue: fixture.family))
            var parser = TranscriptParser(family: family, agentId: "/tmp/compat.jsonl", fileID: 0)
            var deduper = Deduper()
            var records: [String: ResponseRecord] = [:]
            for line in fixture.lines {
                var text = line
                text.withUTF8 { bytes in
                    parser.consume(rawLine: UnsafeRawBufferPointer(bytes), deduper: &deduper) { records[$0.record.key] = $0.record }
                }
            }
            XCTAssertEqual(records.count, fixture.expected.responseCount, fixture.name)
            XCTAssertEqual(records.values.reduce(0) { $0 + $1.usage.output }, fixture.expected.output, fixture.name)
            XCTAssertEqual(parser.state.phase.rawValue, fixture.expected.phase, fixture.name)
            XCTAssertEqual(parser.state.model, fixture.expected.model, fixture.name)
            XCTAssertEqual(parser.state.localDisplayStopped, fixture.expected.stopped, fixture.name)
        }
    }
}
