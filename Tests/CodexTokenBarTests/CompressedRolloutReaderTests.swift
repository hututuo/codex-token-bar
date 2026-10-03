import Foundation
import XCTest
@testable import CodexTokenBar

final class CompressedRolloutReaderTests: XCTestCase {
    func testPlainJSONLIsReadAndPreferredOverCompressedSibling() throws {
        let root = try temporaryDirectory()
        let plainURL = root.appendingPathComponent("rollout.jsonl")
        let compressedURL = root.appendingPathComponent("rollout.jsonl.zst")
        let plain = Data("plain source\n".utf8)
        try plain.write(to: plainURL)
        try rawFrame(Data("compressed source\n".utf8), singleSegment: true).write(to: compressedURL)

        XCTAssertTrue(CodexRolloutReader.isRollout(plainURL))
        XCTAssertTrue(CodexRolloutReader.isRollout(compressedURL))
        XCTAssertEqual(CodexRolloutReader.logicalURL(compressedURL), plainURL)
        XCTAssertEqual(try CodexRolloutReader.physicalURL(for: compressedURL), plainURL)

        let reader = try CodexRolloutReader(forReadingFrom: compressedURL)
        defer { try? reader.close() }
        XCTAssertFalse(reader.isCompressed)
        XCTAssertEqual(reader.physicalURL, plainURL)
        XCTAssertEqual(try readAll(reader), plain)
    }

    func testDeclaredSingleFrameStreamsAndSeeks() throws {
        let root = try temporaryDirectory()
        let payload = Data("{}\n{\"x\":1}\n".utf8)
        let file = try write(rawFrame(payload, singleSegment: true), named: "known.jsonl.zst", in: root)
        let reader = try CodexRolloutReader(forReadingFrom: file)
        defer { try? reader.close() }

        XCTAssertTrue(reader.isCompressed)
        XCTAssertEqual(reader.layout.logicalSize, UInt64(payload.count))
        XCTAssertTrue(reader.supportsMetadataReuse)
        XCTAssertEqual(try XCTUnwrap(reader.read(upToCount: 6)), Data(payload.prefix(6)))
        XCTAssertEqual(try reader.offset(), 6)
        try reader.seek(toOffset: 2)
        XCTAssertEqual(try XCTUnwrap(reader.read(upToCount: 5)), Data(payload[2..<7]))
        try reader.seek(toOffset: 0)
        XCTAssertEqual(try readAll(reader), payload)
        try reader.validateDecodedEnd(at: UInt64(payload.count))
    }

    func testUnknownSizeFrameMeasuresLengthAndRestoresReadPosition() throws {
        let root = try temporaryDirectory()
        let payload = Data("{\"unknown\":true}\n".utf8)
        let file = try write(rawFrame(payload, singleSegment: false), named: "unknown.jsonl.zst", in: root)
        let reader = try CodexRolloutReader(forReadingFrom: file)
        defer { try? reader.close() }

        XCTAssertNil(reader.layout.logicalSize)
        XCTAssertFalse(reader.supportsMetadataReuse)
        let prefix = try XCTUnwrap(reader.read(upToCount: 4))
        XCTAssertEqual(prefix, Data(payload.prefix(4)))
        XCTAssertEqual(try reader.logicalSize(), UInt64(payload.count))
        XCTAssertEqual(try reader.offset(), 4)
        XCTAssertEqual(prefix + (try readAll(reader)), payload)
    }

    func testConcatenatedFramesSumSizesAndSeekAcrossBoundary() throws {
        let root = try temporaryDirectory()
        let first = Data("{\"a\":1}\n".utf8)
        let second = Data("{\"b\":2}\n".utf8)
        let file = try write(
            rawFrame(first, singleSegment: true) + rawFrame(second, singleSegment: true),
            named: "multi.jsonl.zst", in: root
        )
        let reader = try CodexRolloutReader(forReadingFrom: file)
        defer { try? reader.close() }

        let expected = first + second
        XCTAssertEqual(reader.layout.logicalSize, UInt64(expected.count))
        XCTAssertFalse(reader.layout.singleFrame)
        XCTAssertFalse(reader.supportsMetadataReuse)
        XCTAssertEqual(try readAll(reader), expected)
        try reader.seek(toOffset: UInt64(first.count + 1))
        XCTAssertEqual(
            try XCTUnwrap(reader.read(upToCount: 4)),
            Data(expected[(first.count + 1)..<(first.count + 5)])
        )
    }

    func testTruncatedRawBlockPayloadIsRejected() throws {
        let root = try temporaryDirectory()
        let frame = rawFrame(Data("{\"truncated\":true}\n".utf8), singleSegment: true)
        let file = try write(Data(frame.dropLast()), named: "truncated.jsonl.zst", in: root)
        XCTAssertThrowsError(try CodexRolloutReader(forReadingFrom: file))
    }

    func testUnusedDescriptorBitIsIgnoredButReservedBitIsRejected() throws {
        let root = try temporaryDirectory()
        let payload = Data("{}\n".utf8)
        var valid = rawFrame(payload, singleSegment: true)
        valid[4] |= 0x10 // official decoder ignores descriptor bit 4
        let file = try write(valid, named: "unused.jsonl.zst", in: root)
        let reader = try CodexRolloutReader(forReadingFrom: file)
        defer { try? reader.close() }
        XCTAssertEqual(try readAll(reader), payload)
        try reader.validateDecodedEnd(at: UInt64(payload.count))
        valid[4] |= 0x08 // descriptor bit 3 is reserved and must be zero
        let invalid = try write(valid, named: "reserved.jsonl.zst", in: root)
        XCTAssertThrowsError(try CodexRolloutReader(forReadingFrom: invalid))
    }

    func testObservationUsesPhysicalModificationTimeAndDecodedLogicalSize() throws {
        let root = try temporaryDirectory()
        let payload = Data("{\"logical\":\"size\"}\n".utf8)
        let file = try write(rawFrame(payload, singleSegment: true), named: "mtime.jsonl.zst", in: root)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_120)

        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: file.path)
        let first = try SourceFileObservation.read(at: file)
        XCTAssertEqual(first.size, UInt64(payload.count))
        XCTAssertEqual(first.modifiedAt, firstDate.timeIntervalSince1970, accuracy: 0.01)

        try FileManager.default.setAttributes([.modificationDate: secondDate], ofItemAtPath: file.path)
        let second = try SourceFileObservation.read(at: file)
        XCTAssertEqual(second.size, UInt64(payload.count))
        XCTAssertEqual(second.modifiedAt, secondDate.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNotEqual(first.modifiedAt, second.modifiedAt)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-rollout-reader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func readAll(_ reader: CodexRolloutReader, chunkSize: Int = 5) throws -> Data {
        var output = Data()
        while let part = try reader.read(upToCount: chunkSize), !part.isEmpty {
            output.append(part)
        }
        return output
    }

    private func rawFrame(_ payload: Data, singleSegment: Bool) -> Data {
        precondition(payload.count < 256, "fixture uses the one-byte frame content-size field")
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD])
        if singleSegment {
            frame.append(0x20) // single-segment frame with a one-byte content size
            frame.append(UInt8(payload.count))
        } else {
            frame.append(0x00) // no content-size field
            frame.append(0x00) // window descriptor
        }
        let blockHeader = (UInt32(payload.count) << 3) | 1 // last raw block
        frame.append(UInt8(blockHeader & 0xff))
        frame.append(UInt8((blockHeader >> 8) & 0xff))
        frame.append(UInt8((blockHeader >> 16) & 0xff))
        frame.append(payload)
        return frame
    }
}
