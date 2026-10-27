import Foundation
import Testing
@testable import AgentSpeedCore

enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("spec/fixtures", isDirectory: true)

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Splits a buffer into lines the way the tailer does: newline-terminated lines only, an incomplete last line waits for
/// its newline (METRICS 5), as `reference.py` reads them.
func forEachLine(in data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
    data.withUnsafeBytes { buffer in
        var start = 0
        for index in 0..<buffer.count where buffer[index] == 0x0A {
            body(UnsafeRawBufferPointer(rebasing: buffer[start..<index]))
            start = index + 1
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { self[key] as? String }
}

/// The fields added with the cost feature (METRICS 3.2): `cacheWrite1hInput`, `provider` and `fast`.
func expectPricingFields(
    _ record: ResponseRecord,
    _ wanted: [String: Any],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(record.usage.cacheWrite1hInput == wanted.int("cacheWrite1hInput"), "\(label) cacheWrite1hInput",
            sourceLocation: sourceLocation)
    #expect(record.provider == wanted.string("provider"), "\(label) provider", sourceLocation: sourceLocation)
    #expect(record.fast == (wanted["fast"] as? Bool), "\(label) fast", sourceLocation: sourceLocation)
}
