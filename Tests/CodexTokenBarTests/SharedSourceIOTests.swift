import SharedSourceIO
import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class SharedSourceIOTests: XCTestCase {
    func testConsumersSharePhysicalRangesAndKeepIndependentOffsets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = Data((0..<200_000).map { UInt8($0 % 251) })
        try input.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        let first = try FileHandle(forReadingFrom:url), second = try FileHandle(forReadingFrom:url)
        defer { try? first.close(); try? second.close() }
        let broker = SharedSourceIO()
        XCTAssertEqual(try broker.read(descriptor:first.fileDescriptor,offset:0,count:140_000),input.prefix(140_000))
        let reads = broker.statistics.physicalReads
        XCTAssertEqual(try broker.read(descriptor:second.fileDescriptor,offset:20_000,count:100_000),input[20_000..<120_000])
        XCTAssertEqual(broker.statistics.physicalReads,reads)
        XCTAssertGreaterThan(broker.statistics.cacheHits,0)
        XCTAssertEqual(try first.offset(),0); XCTAssertEqual(try second.offset(),0)
        _ = try broker.read(descriptor:first.fileDescriptor,offset:100,count:128,probe:true)
        XCTAssertGreaterThan(broker.statistics.physicalReads,reads)
    }
    func testRewriteAppendTruncateAndReplacementCannotReuseOldPages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        try Data(repeating:1,count:100).write(to:url)
        let broker = SharedSourceIO(maxCacheBytes:128*1024,maxOwners:2)
        func read() throws -> Data { let f = try FileHandle(forReadingFrom:url); defer { try? f.close() }; return try broker.read(descriptor:f.fileDescriptor,offset:0,count:1000) }
        XCTAssertEqual(try read(),Data(repeating:1,count:100))
        let f = try FileHandle(forWritingTo:url)
        try f.write(contentsOf:Data(repeating:2,count:100)); try f.synchronize(); try f.close()
        XCTAssertEqual(try read(),Data(repeating:2,count:100))
        let append = try FileHandle(forWritingTo:url); try append.seekToEnd(); try append.write(contentsOf:Data([3])); try append.close()
        XCTAssertEqual(try read().last,3)
        try Data([4]).write(to:url,options:.atomic)
        XCTAssertEqual(try read(),Data([4]))
        XCTAssertLessThanOrEqual(broker.statistics.cachedBytes,128*1024)
    }
    func testHardLinksUseOneCacheAndNestedValidationAlwaysReadsPhysicalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        let bytes = Data(repeating: 7, count: 150_000)
        try bytes.write(to: one)
        try FileManager.default.linkItem(at: one, to: two)
        let a = try FileHandle(forReadingFrom: one), b = try FileHandle(forReadingFrom: two)
        defer { try? a.close(); try? b.close() }
        let broker = SharedSourceIO()
        XCTAssertEqual(try broker.read(descriptor: a.fileDescriptor, offset: 65_000, count: 70_000), bytes[65_000..<135_000])
        let reads = broker.statistics.physicalReads
        XCTAssertEqual(try broker.read(descriptor: b.fileDescriptor, offset: 66_000, count: 68_000), bytes[66_000..<134_000])
        XCTAssertEqual(broker.statistics.physicalReads, reads)
        try broker.withUncachedReads {
            _ = try broker.read(descriptor: b.fileDescriptor, offset: 66_000, count: 100)
            try broker.withUncachedReads { _ = try broker.read(descriptor: a.fileDescriptor, offset: 66_000, count: 100) }
            _ = try broker.read(descriptor: b.fileDescriptor, offset: 66_000, count: 100)
        }
        XCTAssertEqual(broker.statistics.physicalReads, reads + 3)
        _ = try broker.read(descriptor: a.fileDescriptor, offset: 66_000, count: 100)
        XCTAssertEqual(broker.statistics.physicalReads, reads + 3)
    }
    func testBoundsEvictionAndInPlaceTruncateCannotReturnOldBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 9, count: 256 * 1024).write(to: url)
        let f = try FileHandle(forReadingFrom: url), writer = try FileHandle(forWritingTo: url)
        defer { try? f.close(); try? writer.close() }
        let broker = SharedSourceIO(maxCacheBytes: 64 * 1024, maxOwners: 1)
        XCTAssertEqual(try broker.read(descriptor: f.fileDescriptor, offset: 0, count: 256 * 1024).count, 256 * 1024)
        XCTAssertLessThanOrEqual(broker.statistics.cachedBytes, 64 * 1024)
        try writer.truncate(atOffset: 3)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data([1,2,3]))
        XCTAssertEqual(try broker.read(descriptor: f.fileDescriptor, offset: 0, count: 256 * 1024), Data([1,2,3]))
        XCTAssertEqual(try broker.read(descriptor: f.fileDescriptor, offset: 3, count: 1), Data())
        XCTAssertThrowsError(try broker.read(descriptor: f.fileDescriptor, offset: -1, count: 1))
        XCTAssertThrowsError(try broker.read(descriptor: f.fileDescriptor, offset: 0, count: -1))
    }

}
