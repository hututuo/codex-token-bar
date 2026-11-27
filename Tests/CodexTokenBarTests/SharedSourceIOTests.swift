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

    func testDefaultBudgetEvictsOldPagesButKeepsFreshReadsCorrect() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = Data(repeating: 7, count: 1024 * 1024)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        for _ in 0..<20 { try writer.write(contentsOf: chunk) }
        try writer.close()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let broker = SharedSourceIO()
        for index in 0..<20 {
            XCTAssertEqual(try broker.read(descriptor: reader.fileDescriptor,
                                          offset: Int64(index * chunk.count), count: chunk.count), chunk)
        }
        XCTAssertLessThanOrEqual(broker.statistics.cachedBytes, 4 * 1024 * 1024)
        let reads = broker.statistics.physicalReads
        XCTAssertEqual(try broker.read(descriptor: reader.fileDescriptor, offset: 0, count: chunk.count), chunk)
        XCTAssertGreaterThan(broker.statistics.physicalReads, reads)
        let afterReload = broker.statistics.physicalReads
        XCTAssertEqual(try broker.read(descriptor: reader.fileDescriptor, offset: 0, count: chunk.count), chunk)
        XCTAssertEqual(broker.statistics.physicalReads, afterReload)
    }

    func testPreadSharesCrossPageTailBytesWithoutMovingConsumerOffsets() throws {
        let pageBytes = 64 * 1024
        let sentinel: UInt8 = 0xd3
        let input = Data((0..<(2 * pageBytes + 137)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try input.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try FileHandle(forReadingFrom: url), second = try FileHandle(forReadingFrom: url)
        defer { try? first.close(); try? second.close() }
        try first.seek(toOffset: 37)
        try second.seek(toOffset: 119)
        let broker = SharedSourceIO()
        var initial = [UInt8](repeating: sentinel, count: pageBytes + 100)
        let initialOffset = pageBytes - 17
        let initialCount = initial.withUnsafeMutableBytes {
            broker.pread(first.fileDescriptor, into: $0, offset: Int64(initialOffset))
        }
        XCTAssertEqual(initialCount, initial.count)
        XCTAssertEqual(Data(initial), input[initialOffset..<(initialOffset + initial.count)])
        let cached = broker.statistics

        let tailOffset = pageBytes + 31
        let expectedCount = input.count - tailOffset
        var tail = [UInt8](repeating: sentinel, count: pageBytes + 200)
        let tailCount = tail.withUnsafeMutableBytes {
            broker.pread(second.fileDescriptor, into: $0, offset: Int64(tailOffset))
        }
        XCTAssertEqual(tailCount, expectedCount)
        XCTAssertEqual(Data(tail.prefix(expectedCount)), input[tailOffset..<input.count])
        XCTAssertTrue(tail.dropFirst(expectedCount).allSatisfy { $0 == sentinel })
        XCTAssertEqual(broker.statistics.physicalReads, cached.physicalReads)
        XCTAssertGreaterThan(broker.statistics.cacheHits, cached.cacheHits)
        XCTAssertEqual(try first.offset(), 37)
        XCTAssertEqual(try second.offset(), 119)
    }

    func testPreadCopiesMaximumRangeAfterEvictionAndLeavesBytesBeyondCapUntouched() throws {
        let maximum = 4 * 1024 * 1024
        let pageBytes = 64 * 1024
        let sentinel: UInt8 = 0xd3
        let input = Data((0..<(maximum + pageBytes + 41)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try input.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let broker = SharedSourceIO(maxCacheBytes: pageBytes, maxOwners: 1)
        let offset = 31
        var buffer = [UInt8](repeating: sentinel, count: maximum + 257)
        let count = buffer.withUnsafeMutableBytes {
            broker.pread(reader.fileDescriptor, into: $0, offset: Int64(offset))
        }
        XCTAssertEqual(count, maximum)
        XCTAssertEqual(Data(buffer.prefix(maximum)), input[offset..<(offset + maximum)])
        XCTAssertTrue(buffer.dropFirst(maximum).allSatisfy { $0 == sentinel })
        XCTAssertGreaterThan(broker.statistics.physicalReads, 1)
        XCTAssertLessThanOrEqual(broker.statistics.cachedBytes, pageBytes)
    }

    func testPreadProbeAndNestedUncachedReadsBypassWarmPages() throws {
        let pageBytes = 64 * 1024
        let input = Data((0..<(2 * pageBytes + 17)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try input.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let broker = SharedSourceIO()
        let offset = pageBytes - 7
        func consume(probe: Bool = false) {
            var buffer = [UInt8](repeating: 0xd3, count: 32)
            let count = buffer.withUnsafeMutableBytes {
                broker.pread(reader.fileDescriptor, into: $0, offset: Int64(offset), probe: probe)
            }
            XCTAssertEqual(count, buffer.count)
            XCTAssertEqual(Data(buffer), input[offset..<(offset + buffer.count)])
        }
        func requirePhysicalRead(probe: Bool = false) {
            let before = broker.statistics
            consume(probe: probe)
            XCTAssertGreaterThan(broker.statistics.physicalReads, before.physicalReads)
            XCTAssertEqual(broker.statistics.cacheHits, before.cacheHits)
        }
        consume()
        let cachedHits = broker.statistics.cacheHits
        requirePhysicalRead(probe: true)
        broker.withUncachedReads {
            requirePhysicalRead()
            broker.withUncachedReads { requirePhysicalRead() }
            requirePhysicalRead()
        }
        let physicalReads = broker.statistics.physicalReads
        consume()
        XCTAssertEqual(broker.statistics.physicalReads, physicalReads)
        XCTAssertGreaterThan(broker.statistics.cacheHits, cachedHits)
    }

    func testPreadErrorsPreserveBufferIncludingFailureAfterACacheHit() throws {
        let pageBytes = 64 * 1024
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source")
        try Data(repeating: 7, count: 2 * pageBytes + 17).write(to: url)
        let reader = try FileHandle(forReadingFrom: url), writer = try FileHandle(forWritingTo: url)
        defer { try? reader.close(); try? writer.close() }
        let directory = Darwin.open(root.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(directory, 0)
        guard directory >= 0 else { return }
        defer { _ = Darwin.close(directory) }
        let broker = SharedSourceIO()
        var warm = [UInt8](repeating: 0, count: 8)
        let warmCount = warm.withUnsafeMutableBytes {
            broker.pread(reader.fileDescriptor, into: $0, offset: 0)
        }
        XCTAssertEqual(warmCount, warm.count)
        let cachedHits = broker.statistics.cacheHits
        let requests: [(descriptor: Int32, offset: Int64, error: Int32)] = [
            (-1, 0, EBADF),
            (reader.fileDescriptor, -1, EINVAL),
            (directory, 0, EINVAL),
            (writer.fileDescriptor, Int64(pageBytes - 8), EBADF),
        ]
        for request in requests {
            let original = [UInt8](repeating: 0xd3, count: 32)
            var buffer = original
            errno = 0
            let count = buffer.withUnsafeMutableBytes {
                broker.pread(request.descriptor, into: $0, offset: request.offset)
            }
            let observedError = errno
            XCTAssertEqual(count, -1)
            XCTAssertEqual(observedError, request.error)
            XCTAssertEqual(buffer, original)
        }
        XCTAssertGreaterThan(broker.statistics.cacheHits, cachedHits)
    }

    func testPreadEmptyAndEOFRangesDoNotWriteBufferOrReadPhysicalBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([4, 5, 6]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let broker = SharedSourceIO()
        for offset in [Int64(3), 4, Int64.max] {
            let original = [UInt8](repeating: 0xd3, count: 8)
            var buffer = original
            let count = buffer.withUnsafeMutableBytes {
                broker.pread(reader.fileDescriptor, into: $0, offset: offset)
            }
            XCTAssertEqual(count, 0)
            XCTAssertEqual(buffer, original)
        }
        let empty = UnsafeMutableRawBufferPointer(start: nil, count: 0)
        XCTAssertEqual(broker.pread(-1, into: empty, offset: 0), 0)
        errno = 0
        let invalidOffset = broker.pread(-1, into: empty, offset: -1)
        let observedError = errno
        XCTAssertEqual(invalidOffset, -1)
        XCTAssertEqual(observedError, EINVAL)
        XCTAssertEqual(broker.statistics.physicalReads, 0)
        XCTAssertEqual(broker.statistics.cachedBytes, 0)
    }
}
