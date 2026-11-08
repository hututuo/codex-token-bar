import Foundation

/// Local embedding API: read one conversation with the same parser used by the live monitor.
/// No monitor, network client, history database, or source-file mutation is created.
public enum AntigravityUsageRead {
    public struct Result: Sendable {
        public let responses: [ResponseRecord]
        public let malformedRows: Int
    }
    public enum ReadError: Error { case unreadable, unsupported }

    public static func read(path: String) throws -> Result {
        var reader = AntigravityReader(path: path)
        let (batch, outcome) = reader.read()
        guard !outcome.failed, let batch else { throw ReadError.unreadable }
        guard !batch.unsupported else { throw ReadError.unsupported }
        var parser = AntigravityParser(agentId: path, fileID: 0)
        var deduper = Deduper.hashed()
        var records: [String: ResponseRecord] = [:]
        parser.consume(batch, deduper: &deduper) { records[$0.record.key] = $0.record }
        return Result(responses: records.values.sorted { ($0.endMs, $0.key) < ($1.endMs, $1.key) },
                      malformedRows: parser.state.malformedLines)
    }
}
