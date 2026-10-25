import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("JSON scanner")
struct JSONScannerTests {
    /// Validates a whole document as an object, the way the line extractors do.
    static func isValidObject(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var scanner = JSONScanner(buffer)
            do {
                try scanner.beginObject()
                while try scanner.nextMember() != nil { try scanner.skipValue() }
                try scanner.finish()
                return true
            } catch {
                return false
            }
        }
    }

    static func foundationAccepts(_ bytes: [UInt8]) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(bytes), options: [])) is [String: Any]
    }

    @Test(arguments: [
        #"{}"#, #"{"a":1}"#, #" { "a" : [ 1 , 2.5e-3 , -0 , true , false , null ] } "#,
        #"{"a":{"b":{"c":[{}]}},"d":"é\n\"\\\/"}"#, #"{"k":"é漢字🚀"}"#, #"{"":0}"#,
        #"{"a":"🚀"}"#, #"{"n":12345678901234567890123}"#, #"{"a":[[],[[]],{}]}"#,
    ])
    func acceptsValidObjects(_ text: String) {
        let bytes = Array(text.utf8)
        #expect(Self.foundationAccepts(bytes))
        #expect(Self.isValidObject(bytes))
    }

    @Test(arguments: [
        "", " ", "[]", "1", #""a""#, "{", "}", #"{"a"}"#, #"{"a":}"#, #"{"a":1,}"#, #"{,}"#, #"{"a":1 "b":2}"#,
        #"{"a":01}"#, #"{"a":1.}"#, #"{"a":.5}"#, #"{"a":-}"#, #"{"a":1e}"#, #"{"a":tru}"#, #"{"a":nul}"#,
        #"{"a":"\x"}"#, #"{"a":"\u12"}"#, "{\"a\":\"tab\there\"}", #"{"a":[1,]}"#, #"{"a":[1}"#, #"{"a":1}}"#,
        #"{"a":1} x"#, #"{'a':1}"#, #"{a:1}"#,
    ])
    func rejectsInvalidDocuments(_ text: String) {
        // Strict RFC 8259 like System.Text.Json; Foundation is laxer (it accepts trailing commas).
        #expect(!Self.isValidObject(Array(text.utf8)))
    }

    @Test func rejectsInvalidUTF8() {
        let cases: [[UInt8]] = [
            Array(#"{"a":""#.utf8) + [0xFF] + Array(#""}"#.utf8),
            Array(#"{"a":""#.utf8) + [0xC0, 0xAF] + Array(#""}"#.utf8),
            Array(#"{"a":""#.utf8) + [0xED, 0xA0, 0x80] + Array(#""}"#.utf8),
            Array(#"{"a":""#.utf8) + [0xE2, 0x82] + Array(#""}"#.utf8),
            Array(#"{"a":""#.utf8) + [0xF4, 0x90, 0x80, 0x80] + Array(#""}"#.utf8),
            Array(#"{"a":1}"#.utf8) + [0x80],
        ]
        for bytes in cases {
            #expect(!Self.isValidObject(bytes))
        }
    }

    @Test func limitsNestingDepth() {
        func nested(_ depth: Int) -> [UInt8] {
            Array((String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)).utf8)
        }
        #expect(Self.isValidObject(nested(JSONScanner.maxDepth)))
        #expect(!Self.isValidObject(nested(JSONScanner.maxDepth + 1)))
        let hostile = Array(("{\"a\":" + String(repeating: "[", count: 100_000)).utf8)
        #expect(!Self.isValidObject(hostile))
    }

    @Test func agreesWithFoundationOnMutatedDocuments() {
        let seed = Array(#"{"type":"assistant","message":{"id":"m","usage":{"output_tokens":12,"x":[1,2.5,{"y":null}]},"content":[{"type":"text","text":"a\nbé"}]},"ok":true}"#.utf8)
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array(#"{}[]:,"\0123456789.eE+-truefalsn \u"#.utf8)
        for _ in 0..<3000 {
            var bytes = seed
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: bytes[index] = alphabet.randomElement(using: &generator)!
                case 1: bytes.remove(at: index)
                default: bytes.insert(alphabet.randomElement(using: &generator)!, at: index)
                }
                if bytes.isEmpty { bytes = seed }
            }
            let expected = Self.foundationAccepts(bytes)
            let actual = Self.isValidObject(bytes)
            if expected != actual {
                // Foundation tolerates a few things JSON forbids (e.g. lone surrogate escapes); only flag
                // documents where we accept something Foundation rejects as structurally invalid.
                #expect(!actual || expected, "accepted invalid: \(String(decoding: bytes, as: UTF8.self))")
            }
        }
    }

    @Test func readsSelectedValues() throws {
        let text = #"{"type":"assistant","n":-12,"f":3.99,"big":99999999999999999999,"b":true,"s":"[Request interrupted by user]","nested":{"type":"inner"}}"#
        let bytes = Array(text.utf8)
        try bytes.withUnsafeBytes { buffer in
            var scanner = JSONScanner(buffer)
            try scanner.beginObject()
            var seen: [String: String] = [:]
            while let key = try scanner.nextMember() {
                if scanner.key(key, is: "type") {
                    seen["type"] = try scanner.readStringMatch(["user", "assistant"]).map(String.init)
                } else if scanner.key(key, is: "n") {
                    seen["n"] = try scanner.readInteger().map(String.init)
                } else if scanner.key(key, is: "f") {
                    seen["f"] = try scanner.readInteger().map(String.init)
                } else if scanner.key(key, is: "big") {
                    seen["big"] = try scanner.readInteger().map(String.init)
                } else if scanner.key(key, is: "b") {
                    seen["b"] = try scanner.readBool().map(String.init)
                } else if scanner.key(key, is: "s") {
                    seen["s"] = try scanner.readStringHasPrefix("[Request interrupted by user").map(String.init)
                } else {
                    try scanner.skipValue()
                }
            }
            try scanner.finish()
            #expect(seen == ["type": "1", "n": "-12", "f": "3", "big": String(Int64.max), "b": "true", "s": "true"])
        }
    }

    @Test func clampsTokenCounts() {
        #expect(TokenCount.clamp(nil) == 0)
        #expect(TokenCount.clamp(-5) == 0)
        #expect(TokenCount.clamp(Int64.max) == Int(TokenCount.ceiling))
        #expect(TokenCount.clamp(42) == 42)
    }
}

@Suite("Timestamps")
struct TimestampTests {
    @Test(arguments: [
        ("2026-10-20T10:00:00Z", Int64(1_792_490_400_000)),
        ("2026-10-20T10:00:00.5Z", 1_792_490_400_500),
        ("2026-10-20T10:00:00.123456789Z", 1_792_490_400_123),
        ("2026-10-20T18:00:00+08:00", 1_792_490_400_000),
        ("2026-10-20T05:30:00-0430", 1_792_490_400_000),
        ("2026-10-20 10:00:00.010z", 1_792_490_400_010),
        ("1970-01-01T00:00:00Z", 0),
        ("2024-02-29T00:00:00Z", 1_709_164_800_000),
    ])
    func parsesValidTimestamps(_ text: String, _ expected: Int64) {
        #expect(Timestamp.parse(text) == expected)
    }

    @Test(arguments: [
        "", "2026-10-20", "2026-10-20T10:00:00", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z",
        "2025-02-29T00:00:00Z", "2026-10-20T24:00:00Z", "2026-10-20T10:60:00Z", "2026-10-20T10:00:00.Z",
        "2026-10-20T10:00:00Zjunk", "2026-10-20T10:00:00+0800x", "abcd-10-20T10:00:00Z",
    ])
    func rejectsInvalidTimestamps(_ text: String) {
        #expect(Timestamp.parse(text) == nil)
    }
}
