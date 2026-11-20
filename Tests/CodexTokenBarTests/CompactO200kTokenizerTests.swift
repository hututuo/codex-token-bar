import Foundation
import TiktokenSwift
import XCTest
@testable import CodexTokenBar

final class CompactO200kTokenizerTests: XCTestCase {
    func testCompactEncodingMatchesExistingEncoderTokenForToken() throws {
        let url = try XCTUnwrap(AppResources.url(forResource: "o200k_base", withExtension: "tiktoken"))
        let data = try Data(contentsOf: url)
        let compact = try CompactO200kTokenizer(vocabulary: data)
        XCTAssertLessThan(compact.retainedVocabularyBytes, 12 * 1_048_576)
        let mappedURL = try XCTUnwrap(AppResources.url(forResource: "o200k_base", withExtension: "ctbvocab"))
        let mapped = try CompactO200kTokenizer(mappedVocabularyURL: mappedURL)
        XCTAssertEqual(mapped.retainedVocabularyBytes, 0, "Fixed vocabulary must not be rebuilt on the malloc heap")
        XCTAssertLessThan(mapped.mappedVocabularyBytes, 5 * 1_048_576)
        var ranks: [[UInt8]: UInt32] = [:]
        var tokenSamples: [String] = []
        for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
            let parts = line.split(separator: " ")
            let bytes = try XCTUnwrap(Data(base64Encoded: String(parts[0])))
            ranks[Array(bytes)] = try XCTUnwrap(UInt32(parts[1]))
            if index % 131 == 0, let text = String(data: bytes, encoding: .utf8) { tokenSamples.append(text) }
        }
        let reference = try newCoreBpe(encoder: ranks,
            specialTokensEncoder: ["<|endoftext|>": 199999, "<|endofprompt|>": 200018],
            pattern: CompactO200kTokenizer.pattern)
        let examples = [
            "", "hello world", "你好世界", "can't I'M we'll You'Re",
            " \t\r\n \n  \r\n  ", "foo1234567890bar", "===>//!{}[]\\\"'<|endoftext|>",
            "👩‍💻🏳️‍🌈e\u{301} 中文。日本語 한글 العربية हिन्दी русский",
            "let text = \"你好\";\n// comment\nfunc f(x: Int) -> Int { x + 12345 }",
            String(repeating: "hello world ", count: 3000),
            String(repeating: "a", count: 16_387),
            String(repeating: "-_.", count: 6000),
            String(repeating: "你好😊\n", count: 2000)
        ]
        let alphabet = Array("abcXYZ0123456789 \t\n\r.,;:!?-/\\'\"(){}[]你好世界éàÜßΩяاक한😊")
        var random: UInt64 = 0x7094
        var randomExamples: [String] = []
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<120 {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                text.append(alphabet[Int((random >> 32) % UInt64(alphabet.count))])
            }
            randomExamples.append(text)
        }
        for text in examples + tokenSamples + randomExamples {
            let expected = reference.encodeOrdinary(text: text)
            XCTAssertEqual(compact.encodeOrdinary(text: text), expected, String(text.prefix(100)))
            XCTAssertEqual(mapped.encodeOrdinary(text: text), expected, String(text.prefix(100)))
        }
    }

    func testMappedVocabularyRejectsCorruptOrTruncatedArtifact() throws {
        let source = try XCTUnwrap(AppResources.url(forResource: "o200k_base", withExtension: "ctbvocab"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var data = try Data(contentsOf: source)
        data[data.count - 1] ^= 1
        try data.write(to: path)
        XCTAssertThrowsError(try CompactO200kTokenizer(mappedVocabularyURL: path))
        try data.prefix(32).write(to: path)
        XCTAssertThrowsError(try CompactO200kTokenizer(mappedVocabularyURL: path))
    }

    func testMappedLookupSurvivesAtomicResourceReplacementAndConcurrentReads() async throws {
        let source = try XCTUnwrap(AppResources.url(forResource: "o200k_base", withExtension: "ctbvocab"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.copyItem(at: source, to: path)
        let tokenizer = try CompactO200kTokenizer(mappedVocabularyURL: path)
        let text = "你好 world 👩‍💻 123456\n"
        let expected = tokenizer.encodeOrdinary(text: text)
        try Data("replaced".utf8).write(to: path, options: .atomic)
        let results = await withTaskGroup(of: [UInt32].self, returning: [[UInt32]].self) { group in
            for _ in 0..<32 { group.addTask { tokenizer.encodeOrdinary(text: text) } }
            var result: [[UInt32]] = []
            for await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
        XCTAssertThrowsError(try CompactO200kTokenizer(mappedVocabularyURL: path))
    }

    func testCorruptVocabularyCannotProducePlausibleCounts() {
        XCTAssertThrowsError(try CompactO200kTokenizer(vocabulary: Data("broken 1\n".utf8)))
    }
}
