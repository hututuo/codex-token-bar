import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("File tailer")
struct FileTailerTests {
    final class Collector {
        var lines: [String] = []
        var resets = 0
    }

    static func read(_ tailer: inout FileTailer, into collector: Collector) -> FileTailer.ReadResult {
        tailer.read(onReset: { collector.resets += 1 }) { bytes in
            collector.lines.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test func buffersPartialLinesUntilNewline() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "one\ntw")
        var tailer = FileTailer(path: directory.file("a.jsonl").path)
        let collector = Collector()
        let first = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["one"])
        #expect(first.bytesRead == 6)
        try directory.append("a.jsonl", "o\nthree\n")
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["one", "two", "three"])
        let idle = Self.read(&tailer, into: collector)
        #expect(idle.bytesRead == 0)
        #expect(!idle.didReset)
        #expect(tailer.offset == 14)
    }

    @Test func truncationRestartsFromZero() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "first line\nsecond line\n")
        var tailer = FileTailer(path: directory.file("a.jsonl").path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        try Data("new\n".utf8).write(to: directory.file("a.jsonl"))
        let result = Self.read(&tailer, into: collector)
        #expect(result.didReset)
        #expect(collector.resets == 1)
        #expect(collector.lines == ["first line", "second line", "new"])
    }

    @Test func identityChangeRestartsFromZero() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "old\n")
        var tailer = FileTailer(path: directory.file("a.jsonl").path)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        try directory.write("b.jsonl", "replacement line\n")
        _ = try FileManager.default.replaceItemAt(directory.file("a.jsonl"), withItemAt: directory.file("b.jsonl"))
        let result = Self.read(&tailer, into: collector)
        #expect(result.didReset)
        #expect(collector.lines == ["old", "replacement line"])
    }

    @Test func skipsOversizedLines() throws {
        let directory = try TempDirectory()
        let long = String(repeating: "x", count: 40)
        try directory.write("a.jsonl", "ok\n\(long)\nfine\n" + String(repeating: "y", count: 10))
        var tailer = FileTailer(path: directory.file("a.jsonl").path, maxLineBytes: 16)
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["ok", "fine"])
        #expect(tailer.oversizedLines == 1)
        // The pending fragment grows past the limit across appends and is dropped as one line.
        try directory.append("a.jsonl", String(repeating: "y", count: 10))
        try directory.append("a.jsonl", "yyy\nafter\n")
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["ok", "fine", "after"])
        #expect(tailer.oversizedLines == 2)
    }

    @Test func startAtEndSkipsAnUnterminatedLine() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "complete\npart")
        let size = try #require(FileStat.lstat(directory.file("a.jsonl").path)).size
        var tailer = FileTailer(path: directory.file("a.jsonl").path, start: .end(size))
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines.isEmpty)
        try directory.append("a.jsonl", "ial\nnext\n")
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["next"])
    }

    @Test func startAtEndKeepsALineThatBeginsThere() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "complete\n")
        let size = try #require(FileStat.lstat(directory.file("a.jsonl").path)).size
        var tailer = FileTailer(path: directory.file("a.jsonl").path, start: .end(size))
        let collector = Collector()
        try directory.append("a.jsonl", "appended\n")
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["appended"])
    }

    @Test func tailStartAlignsToTheNextNewline() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "aaaa\nbbbb\ncccc\n")
        var tailer = FileTailer(path: directory.file("a.jsonl").path, start: .tail(8))
        let collector = Collector()
        _ = Self.read(&tailer, into: collector)
        #expect(collector.lines == ["cccc"])
    }

    @Test func refusesSymlinks() throws {
        let directory = try TempDirectory()
        try directory.write("real.jsonl", "line\n")
        try FileManager.default.createSymbolicLink(at: directory.file("link.jsonl"), withDestinationURL: directory.file("real.jsonl"))
        var tailer = FileTailer(path: directory.file("link.jsonl").path)
        let collector = Collector()
        let result = Self.read(&tailer, into: collector)
        #expect(result.failed)
        #expect(collector.lines.isEmpty)
    }

    @Test func readsLinesLargerThanOneChunk() throws {
        let directory = try TempDirectory()
        let big = "{\"a\":\"" + String(repeating: "z", count: FileTailer.chunkBytes + 100) + "\"}"
        try directory.write("a.jsonl", big + "\n{\"b\":1}\n")
        var tailer = FileTailer(path: directory.file("a.jsonl").path)
        var sizes: [Int] = []
        _ = tailer.read { sizes.append($0.count) }
        #expect(sizes == [big.utf8.count, 7])
    }
}

@Suite("Discovery")
struct DiscoveryTests {
    @Test func findsTranscriptsWithinLimits() throws {
        let directory = try TempDirectory()
        try directory.write("a.jsonl", "")
        try directory.write("1/2/3/4/5/six.jsonl", "")
        try directory.write("1/2/3/4/5/6/seven.jsonl", "")
        try directory.write("1/2/3/4/5/6/7/eight.jsonl", "")
        try directory.write("notes.txt", "")
        try directory.write("x/elsewhere.jsonl", "")
        try FileManager.default.createSymbolicLink(at: directory.file("linked"), withDestinationURL: directory.file("x"))
        try FileManager.default.createSymbolicLink(at: directory.file("link.jsonl"), withDestinationURL: directory.file("a.jsonl"))
        let found = TranscriptDiscovery.enumerate(root: directory.path).map { String($0.path.dropFirst(directory.path.count + 1)) }
        #expect(Set(found) == ["a.jsonl", "1/2/3/4/5/six.jsonl", "1/2/3/4/5/6/seven.jsonl", "x/elsewhere.jsonl"])
    }

    @Test func keepsTheMostRecentFilesWhenCapped() throws {
        let directory = try TempDirectory()
        let now = Date()
        for index in 0..<5 {
            try directory.write("f\(index).jsonl", "", modified: now.addingTimeInterval(TimeInterval(index * 60)))
        }
        let kept = TranscriptDiscovery.enumerate(root: directory.path, maxFiles: 3).map { ($0.path as NSString).lastPathComponent }
        #expect(kept == ["f4.jsonl", "f3.jsonl", "f2.jsonl"])
    }

    @Test func ordersByModificationTimeThenPath() {
        func file(_ path: String, _ ns: Int64) -> DiscoveredFile {
            DiscoveredFile(path: path, stat: FileStat(identity: FileIdentity(device: 1, inode: 1), size: 0, modifiedNs: ns, isRegularFile: true))
        }
        let files = [file("/b", 200), file("/c", 100), file("/a", 200), file("/d", 250)]
        #expect(files.sorted(by: TranscriptDiscovery.startupOrder).map(\.path) == ["/c", "/a", "/b", "/d"])
    }
}
