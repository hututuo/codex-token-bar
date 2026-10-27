import Foundation
import Testing
@testable import AgentSpeedCore

/// Hand-built zstd frames (raw blocks, no content size), so the tests need no compressor.
enum ZstdFrames {
    static func raw(_ text: String, badChecksum: Bool = false) -> [UInt8] {
        raw(Array(text.utf8), badChecksum: badChecksum)
    }

    /// With `badChecksum`, the frame declares a content checksum that cannot match.
    static func raw(_ content: [UInt8], badChecksum: Bool = false) -> [UInt8] {
        // Magic, frame header descriptor (bit 2: checksum), window descriptor (2 MiB).
        var frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, badChecksum ? 0x04 : 0x00, 0x58]
        var start = 0
        repeat {
            let end = min(content.count, start + 128 * 1024)
            frame += blockHeader(size: end - start, type: 0, last: end == content.count)
            frame += content[start..<end]
            start = end
        } while start < content.count
        if badChecksum { frame += [0xDE, 0xAD, 0xBE, 0xEF] }
        return frame
    }

    static func skippable(_ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count)
        return [0x53, 0x2A, 0x4D, 0x18] + withUnsafeBytes(of: size.littleEndian, Array.init) + payload
    }

    /// Structurally complete, but its compressed block is garbage.
    static func corruptBlock() -> [UInt8] {
        [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58] + blockHeader(size: 4, type: 2, last: true) + [0xFF, 0xFF, 0xFF, 0xFF]
    }

    private static func blockHeader(size: Int, type: Int, last: Bool) -> [UInt8] {
        let value = UInt32(size << 3 | type << 1 | (last ? 1 : 0))
        return [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)]
    }
}

extension TempDirectory {
    @discardableResult
    func write(_ relative: String, bytes: [UInt8], modified: Date? = nil) throws -> URL {
        let target = file(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    func append(_ relative: String, bytes: [UInt8]) throws {
        let handle = try FileHandle(forWritingTo: file(relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
    }
}

@Suite("zstd frame tailer")
struct ZstdFrameTailerTests {
    final class Collector {
        var lines: [String] = []
        var malformed = 0
        var resets = 0
    }

    static let name = "session.v4.jsonl.zstd"

    static func read(_ tailer: inout ZstdFrameTailer, into collector: Collector) -> FileTailer.ReadResult {
        tailer.read(onReset: { collector.resets += 1 }, onMalformed: { collector.malformed += 1 }) { bytes in
            collector.lines.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test func decodesFramesAndJoinsLinesAcrossFrameBoundaries() throws {
        let directory = try TempDirectory()
        let bytes = ZstdFrames.raw("one\ntw") + ZstdFrames.raw("o\n") + ZstdFrames.raw("") + ZstdFrames.raw("three\n")
        try directory.write(Self.name, bytes: bytes)
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        let result = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["one", "two", "three"])
        #expect(collector.malformed == 0)
        #expect(result.bytesRead == bytes.count)
        #expect(tailer.offset == Int64(bytes.count))
        #expect(Self.read(&tailer, into: collector).bytesRead == 0)
    }

    @Test func waitsForAPartialTrailingFrame() throws {
        let directory = try TempDirectory()
        let second = ZstdFrames.raw("second\n")
        try directory.write(Self.name, bytes: ZstdFrames.raw("first\n") + second.prefix(2))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["first"])
        try directory.append(Self.name, bytes: Array(second[2..<9]))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["first"])
        try directory.append(Self.name, bytes: Array(second[9...]))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["first", "second"])
        #expect(collector.malformed == 0)
        #expect(!tailer.isResynchronizing)
    }

    @Test func skipsACorruptFrameAsOneMalformedLine() throws {
        let directory = try TempDirectory()
        let bytes = ZstdFrames.raw("a\n") + ZstdFrames.raw("lost\nlines\n", badChecksum: true) + ZstdFrames.corruptBlock()
            + ZstdFrames.raw("b\n")
        try directory.write(Self.name, bytes: bytes)
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a", "b"])
        #expect(collector.malformed == 2)
        #expect(!tailer.isResynchronizing)
    }

    @Test func skipsSkippableFramesEvenWhenTheyArriveInPieces() throws {
        let directory = try TempDirectory()
        let skippable = ZstdFrames.skippable(Array(repeating: 0x7A, count: 40))
        try directory.write(Self.name, bytes: ZstdFrames.raw("a\n") + ZstdFrames.skippable([1, 2, 3]) + skippable.prefix(12))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        try directory.append(Self.name, bytes: Array(skippable[12...]) + ZstdFrames.raw("b\n"))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a", "b"])
        #expect(collector.malformed == 0)
    }

    @Test func framesBeyondTheOutputCapAreMalformed() throws {
        let directory = try TempDirectory()
        try directory.write(Self.name, bytes: ZstdFrames.raw("fits\n") + ZstdFrames.raw("much too long\n") + ZstdFrames.raw("ok\n"))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path, maxFrameOutputBytes: 8)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["fits", "ok"])
        #expect(collector.malformed == 1)
    }

    @Test func decodesFramesLargerThanTheInitialOutputBuffer() throws {
        let directory = try TempDirectory()
        let line = String(repeating: "x", count: 300 * 1024)
        try directory.write(Self.name, bytes: ZstdFrames.raw(line + "\n" + line + "\n"))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines.map(\.count) == [line.count, line.count])
    }

    @Test func startAtEndReadsOnlyAppendedFrames() throws {
        let directory = try TempDirectory()
        try directory.write(Self.name, bytes: ZstdFrames.raw("old\n"))
        let size = try #require(FileStat.lstat(directory.file(Self.name).path)).size
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path, start: .end(size))
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines.isEmpty)
        try directory.append(Self.name, bytes: ZstdFrames.raw("new\n") + ZstdFrames.raw("newer\n"))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["new", "newer"])
    }

    @Test func truncationAndReplacementRestartFromZero() throws {
        let directory = try TempDirectory()
        try directory.write(Self.name, bytes: ZstdFrames.raw("first\n") + ZstdFrames.raw("second\n"))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        try Data(ZstdFrames.raw("short\n")).write(to: directory.file(Self.name))
        #expect(Self.read(&tailer, into: collector).didReset)
        try directory.write("other.zstd", bytes: ZstdFrames.raw("replacement\n"))
        _ = try FileManager.default.replaceItemAt(directory.file(Self.name), withItemAt: directory.file("other.zstd"))
        #expect(Self.read(&tailer, into: collector).didReset)
        #expect(collector.lines == ["first", "second", "short", "replacement"])
        #expect(collector.resets == 2)
    }

    @Test func resynchronizesAtTheNextFrameAfterBytesThatAreNotAFrame() throws {
        let directory = try TempDirectory()
        let garbage = Array("not zstd at all".utf8)
        try directory.write(Self.name, bytes: ZstdFrames.raw("a\n") + garbage + ZstdFrames.raw("b\n")
            + ZstdFrames.skippable([0x28, 0xB5, 0x2F, 0xFD]) + ZstdFrames.raw("c\n"))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a", "b", "c"])
        #expect(collector.malformed == 1)
        #expect(!tailer.isResynchronizing)
    }

    @Test func garbageAtTheEndWaitsForTheNextFrame() throws {
        let directory = try TempDirectory()
        let frame = ZstdFrames.raw("later\n")
        try directory.write(Self.name, bytes: ZstdFrames.raw("a\n") + Array("garbage written last".utf8))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a"])
        #expect(collector.malformed == 1)
        #expect(tailer.isResynchronizing)
        // More garbage, then a frame whose magic arrives split across two appends.
        try directory.append(Self.name, bytes: Array(" and more".utf8) + frame.prefix(2))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.malformed == 1)
        try directory.append(Self.name, bytes: Array(frame[2...]) + ZstdFrames.raw("next\n"))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a", "later", "next"])
        #expect(collector.malformed == 1)
        #expect(!tailer.isResynchronizing)
    }

    @Test func aFewTrailingBytesWaitWithoutCountingAsMalformed() throws {
        let directory = try TempDirectory()
        try directory.write(Self.name, bytes: ZstdFrames.raw("a\n") + Array("xyz".utf8))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.malformed == 0)
        try directory.append(Self.name, bytes: ZstdFrames.raw("b\n"))
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["a", "b"])
        #expect(collector.malformed == 1)
    }

    @Test func refusesSymlinks() throws {
        let directory = try TempDirectory()
        try directory.write("real.zstd", bytes: ZstdFrames.raw("line\n"))
        try FileManager.default.createSymbolicLink(at: directory.file(Self.name), withDestinationURL: directory.file("real.zstd"))
        var tailer = ZstdFrameTailer(path: directory.file(Self.name).path)
        let collector = Collector()
        #expect(Self.read(&tailer, into: collector).failed)
        #expect(collector.lines.isEmpty)
    }

    @Test func decodesRealCompressedFrames() throws {
        let fixture = Fixtures.root.appendingPathComponent(
            "dsh/sessions/--Users-dev-projects-quasar--/session-dsh-main/session.v4.jsonl.zstd"
        )
        var reader = TranscriptReader(path: fixture.path)
        var lines: [String] = []
        var malformed = 0
        let result = reader.read(onMalformed: { malformed += 1 }) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(!result.failed)
        #expect(malformed == 0)
        #expect(lines.count == 17)
        #expect(lines.first?.hasPrefix(#"{"type":"session""#) == true)
        #expect(lines.last == "this line is not json")
    }
}
