import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Display-only failure metadata")
struct LocalDisplayStopTests {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    @Test func codexErrorKeepsReportPhaseAndResumesOnOutput() {
        let id: FileID = 1
        var parser = CodexParser(agentId: "test", fileID: id), deduper = Deduper()
        for text in [
            #"{"timestamp":"2026-10-26T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-26T10:00:01Z","type":"event_msg","payload":{"type":"stream_error"}}"#,
        ] {
            bytes(text).withUnsafeBytes { parser.consume(CodexLineExtractor.extract($0), deduper: &deduper) { _ in } }
        }
        #expect(parser.state.phase == .generating)
        #expect(parser.state.localDisplayStopped)
        let resumed = #"{"timestamp":"2026-10-26T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant"}}"#
        bytes(resumed).withUnsafeBytes { parser.consume(CodexLineExtractor.extract($0), deduper: &deduper) { _ in } }
        #expect(!parser.state.localDisplayStopped)
    }
    @Test func explicitErrorWithoutTimestampStillStopsOnlyPresentation() {
        var parser = CodexParser(agentId: "test", fileID: 1), deduper = Deduper()
        bytes(#"{"timestamp":"2026-10-26T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#).withUnsafeBytes {
            parser.consume(CodexLineExtractor.extract($0), deduper: &deduper) { _ in }
        }
        let before = parser.state.lastLineMs
        bytes(#"{"type":"event_msg","payload":{"type":"stream_error"}}"#).withUnsafeBytes {
            parser.consume(CodexLineExtractor.extract($0), deduper: &deduper) { _ in }
        }
        #expect(parser.state.localDisplayStopped)
        #expect(parser.state.phase == .generating)
        #expect(parser.state.lastLineMs == before)
    }
    @Test func claudeErrorMarkerAndDshFailureArePresentationOnly() {
        let line = #"{"timestamp":"2026-10-26T10:00:01Z","type":"system","subtype":"api_error"}"#
        bytes(line).withUnsafeBytes {
            guard case .line(let value) = ClaudeLineExtractor.extract($0) else { Issue.record("Expected Claude metadata"); return }
            #expect(value.localDisplayStop)
        }
        let dsh = #"{"type":"event","event":{"type":"request/error","time":1800000000000}}"#
        bytes(dsh).withUnsafeBytes {
            guard case .line(let value) = DshLineExtractor.extract($0),
                  case .event(_, .localDisplayStop) = value.records.first else { Issue.record("Expected DSH stop metadata"); return }
        }
    }
}
