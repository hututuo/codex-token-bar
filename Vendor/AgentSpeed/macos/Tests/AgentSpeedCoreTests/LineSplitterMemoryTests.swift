import Testing
@testable import AgentSpeedCore

@Suite("Line splitter buffer lifetime")
struct LineSplitterMemoryTests {
    private func feed(_ text: String, into splitter: inout LineSplitter, lines: inout [String]) {
        Array(text.utf8).withUnsafeBytes { bytes in
            splitter.consume(bytes) { lines.append(String(decoding: $0, as: UTF8.self)) }
        }
    }

    @Test func largeCompletedLineReleasesCapacityAndPreservesSmallTail() {
        var splitter = LineSplitter(maxLineBytes: 2 * 1024 * 1024)
        var lines: [String] = []
        let large = String(repeating: "x", count: 400_000)
        feed(large, into: &splitter, lines: &lines)
        #expect(lines.isEmpty)
        #expect(splitter.retainedCapacityForTesting >= large.utf8.count)
        feed("\nnext", into: &splitter, lines: &lines)
        #expect(lines == [large])
        #expect(splitter.retainedCapacityForTesting <= 64 * 1024)
        feed(" line\n", into: &splitter, lines: &lines)
        #expect(lines == [large, "next line"])
        #expect(splitter.oversizedLines == 0)
    }

    @Test func completedBufferCanBeReleasedWithoutChangingAnIndependentPartialCopy() {
        var original = LineSplitter(maxLineBytes: 2 * 1024 * 1024)
        var lines: [String] = []
        let large = String(repeating: "y", count: 400_000)
        feed(large, into: &original, lines: &lines)
        var copy = original
        feed("\n", into: &original, lines: &lines)
        #expect(original.retainedCapacityForTesting <= 64 * 1024)
        #expect(copy.retainedCapacityForTesting >= large.utf8.count)
        feed("tail\n", into: &copy, lines: &lines)
        #expect(lines == [large, large + "tail"])
        #expect(copy.retainedCapacityForTesting <= 64 * 1024)
    }

    @Test func oversizedFragmentIsDroppedOnceAndBufferReleased() {
        var splitter = LineSplitter(maxLineBytes: 300_000)
        var lines: [String] = []
        feed(String(repeating: "z", count: 200_000), into: &splitter, lines: &lines)
        feed(String(repeating: "z", count: 200_000), into: &splitter, lines: &lines)
        #expect(splitter.retainedCapacityForTesting <= 64 * 1024)
        feed("discarded\nvalid\n", into: &splitter, lines: &lines)
        #expect(lines == ["valid"])
        #expect(splitter.oversizedLines == 1)
    }
}
