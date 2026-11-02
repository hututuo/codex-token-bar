import Foundation
import CryptoKit
import XCTest
@testable import CodexTokenBar

final class ExactStageRowCodecTests: XCTestCase {
    func testSharedCrossPlatformVectorsRoundTripOrReject() throws {
        struct Row: Decodable { let rowHex: String; let expectedColumns: Int; let sha256: String }
        struct Vectors: Decodable { let validRows: [Row]; let invalidRows: [Row] }
        func bytes(_ hex: String) throws -> Data {
            guard hex.count.isMultiple(of: 2) else { throw ExactStageRowCodec.Failure.invalidRow }
            let chars = Array(hex), result = stride(from: 0, to: chars.count, by: 2).map {
                UInt8(String(chars[$0...($0 + 1)]), radix: 16)
            }
            guard result.allSatisfy({ $0 != nil }) else { throw ExactStageRowCodec.Failure.invalidRow }
            return Data(result.map { $0! })
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("spec/fixtures/exact-stage-row-v1.json")))
        let work = try SQLiteTemporaryDatabase()
        for row in vectors.validRows {
            let encoded = try bytes(row.rowHex)
            XCTAssertEqual(SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(), row.sha256)
            let values = try ExactStageRowCodec.decode(encoded, expectedColumns: row.expectedColumns)
            let query = "SELECT " + Array(repeating: "?", count: row.expectedColumns).joined(separator: ",")
            XCTAssertEqual(try work.connection.readRows(query, bindings: values) { try ExactStageRowCodec.encode($0) }, [encoded])
        }
        for row in vectors.invalidRows {
            XCTAssertThrowsError(try ExactStageRowCodec.decode(bytes(row.rowHex), expectedColumns: row.expectedColumns))
        }
    }
    func testRowsPreserveInt64RealNullTextAndBlobStorageClassesWithoutJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-codec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = SQLiteDatabaseDriver(url: root.appendingPathComponent("fixture.sqlite"), bypassBusinessRoutes: true)
        try db.withConnection { connection in
            try connection.execute("CREATE TABLE restored(a,b,c,d,e,f,g,h,i)")
            let sql = "SELECT 9223372036854775807,-9223372036854775808,9007199254740993,1.2345678901234567,NULL,CAST(x'ff0001' AS TEXT),x'',x'0001ff',''"
            let payload = try XCTUnwrap(connection.readRows(sql) { try ExactStageRowCodec.encode($0) }.first)
            let expected = try XCTUnwrap(connection.readRows(sql) { row in
                (0..<row.columnCount).map { row.canonicalBytes($0) }
            }.first)
            try connection.execute("INSERT INTO restored VALUES(?,?,?,?,?,?,?,?,?)",
                bindings: ExactStageRowCodec.decode(payload, expectedColumns: 9))
            let restored = try XCTUnwrap(connection.readRows("SELECT * FROM restored") { row in
                (0..<row.columnCount).map { row.canonicalBytes($0) }
            }.first)
            XCTAssertEqual(expected, restored)
            let sliced = (Data([0, 0]) + payload).dropFirst(2)
            XCTAssertNoThrow(try ExactStageRowCodec.decode(sliced, expectedColumns: 9))
            XCTAssertThrowsError(try ExactStageRowCodec.decode(payload, expectedColumns: 8))
            XCTAssertThrowsError(try ExactStageRowCodec.decode(payload + Data([0]), expectedColumns: 9))
            XCTAssertThrowsError(try ExactStageRowCodec.decode(Data(payload.dropLast()), expectedColumns: 9))
            for length in 0..<min(payload.count, 20) {
                XCTAssertThrowsError(try ExactStageRowCodec.decode(Data(payload.prefix(length)), expectedColumns: 9))
            }
        }
    }

    func testFutureCodecAndMaliciousLengthsCannotBecomeValidRows() {
        XCTAssertThrowsError(try ExactStageRowCodec.decode(Data([0x54,0x42,0x52,0x02,0,0,0,1]), expectedColumns: 1))
        let overflowingLength = Data([0x54,0x42,0x52,0x01,0,0,0,1,3] + Array(repeating: 255, count: 8))
        XCTAssertThrowsError(try ExactStageRowCodec.decode(overflowingLength, expectedColumns: 1))
        XCTAssertThrowsError(try ExactStageRowCodec.decode(Data(), expectedColumns: Int.max))
    }
}
