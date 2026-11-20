import XCTest
@testable import CodexTokenBar

final class VisibleTextSummaryMemoryTests: XCTestCase {
    func testLargeResponseKeepsBoundedFingerprintAndIdenticalChunkedIdentity() {
        let part = "正文🙂e\u{301} code\n"
        let text = String(repeating: part, count: 20_000)
        let whole = VisibleTextSummary(text: text)
        var chunked = VisibleTextSummary()
        for _ in 0..<20_000 { chunked.append(part) }
        XCTAssertEqual(whole, chunked)
        XCTAssertEqual(whole.utf8Count, text.utf8.count)
        XCTAssertEqual(whole.prefix, Array(text.utf8.prefix(64)))
        XCTAssertEqual(whole.suffix, Array(text.utf8.suffix(64)))
        XCTAssertLessThanOrEqual(whole.suffix.capacity, 128)
        XCTAssertLessThanOrEqual(chunked.suffix.capacity, 128)
        XCTAssertNil(whole.exactText)
    }

    func testEmptyAndSmallAppendsPreserveSuffixAndReferenceHashes() {
        var summary = VisibleTextSummary(text: String(repeating: "x", count: 70))
        summary.append("")
        summary.append("尾🙂")
        let text = String(repeating: "x", count: 70) + "尾🙂"
        var hashA: UInt64 = 14_695_981_039_346_656_037
        var hashB: UInt64 = 5_381
        for byte in text.utf8 {
            hashA = (hashA ^ UInt64(byte)) &* 1_099_511_628_211
            hashB = ((hashB &* 33) ^ UInt64(byte)) &+ 0x9e3779b97f4a7c15
        }
        XCTAssertEqual(summary.hashA, hashA)
        XCTAssertEqual(summary.hashB, hashB)
        XCTAssertEqual(summary.suffix, Array(text.utf8.suffix(64)))
        XCTAssertEqual(summary.exactText, text)
    }
}
