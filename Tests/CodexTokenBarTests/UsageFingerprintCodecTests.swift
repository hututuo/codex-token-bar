import Foundation
import XCTest
@testable import CodexTokenBar

final class UsageFingerprintCodecTests: XCTestCase {
    private let mixedValues: [UInt64] = [
        1,
        127,
        128,
        255,
        300,
        1,
        16_384,
        UInt64(UInt32.max),
        UInt64.max,
        42,
        0,
    ]

    func testCanonicalGoldenVectorsMatchCrossPlatformContract() throws {
        XCTAssertEqual(
            try UsageFingerprintCodec.encode(Array(repeating: 0, count: 11)).hex,
            "010000000000000000000000"
        )
        XCTAssertEqual(
            try UsageFingerprintCodec.encode(mixedValues).hex,
            "01017f8001ff01ac0201808001ffffffff0fffffffffffffffffff012a00"
        )
        XCTAssertEqual(
            try UsageFingerprintCodec.decode(UsageFingerprintCodec.encode(mixedValues)),
            mixedValues
        )
    }

    func testReasoningTokenDifferenceRemainsExact() throws {
        var withoutReasoning = Array(repeating: UInt64(0), count: 11)
        withoutReasoning[0] = 100
        var withReasoning = withoutReasoning
        withReasoning[3] = 1

        XCTAssertNotEqual(
            try UsageFingerprintCodec.encode(withoutReasoning),
            try UsageFingerprintCodec.encode(withReasoning)
        )
    }

    func testLegacyTextAndFixedWidthDecodeToCanonicalVector() throws {
        let legacyText = mixedValues.map(String.init).joined(separator: ":")
        XCTAssertEqual(try UsageFingerprintCodec.decodeLegacyText(legacyText), mixedValues)

        var legacyFixed = Data()
        for value in mixedValues {
            withUnsafeBytes(of: value.littleEndian) { legacyFixed.append(contentsOf: $0) }
        }
        XCTAssertEqual(
            try UsageFingerprintCodec.decodeLegacyFixedWidth(legacyFixed),
            mixedValues
        )
        XCTAssertEqual(
            try UsageFingerprintCodec.encode(
                UsageFingerprintCodec.decodeLegacyFixedWidth(legacyFixed)
            ).hex,
            "01017f8001ff01ac0201808001ffffffff0fffffffffffffffffff012a00"
        )
    }

    func testDecoderRejectsOverlongOverflowAndTrailingRepresentations() throws {
        var overlong = Data([1, 0x80, 0x00])
        overlong.append(contentsOf: Array(repeating: UInt8(0), count: 10))
        XCTAssertThrowsError(try UsageFingerprintCodec.decode(overlong)) { error in
            XCTAssertEqual(error as? UsageFingerprintCodecError, .nonCanonical)
        }

        var overflow = Data([1])
        overflow.append(contentsOf: Array(repeating: UInt8(0xFF), count: 10))
        overflow.append(contentsOf: Array(repeating: UInt8(0), count: 10))
        XCTAssertThrowsError(try UsageFingerprintCodec.decode(overflow)) { error in
            XCTAssertEqual(error as? UsageFingerprintCodecError, .overflow)
        }

        var trailing = try UsageFingerprintCodec.encode(Array(repeating: 0, count: 11))
        trailing.append(0)
        XCTAssertThrowsError(try UsageFingerprintCodec.decode(trailing)) { error in
            XCTAssertEqual(error as? UsageFingerprintCodecError, .trailingBytes)
        }

        var invalidBoolean = Array(repeating: UInt64(0), count: 11)
        invalidBoolean[5] = 2
        XCTAssertThrowsError(try UsageFingerprintCodec.encode(invalidBoolean)) { error in
            XCTAssertEqual(error as? UsageFingerprintCodecError, .invalidBoolean(2))
        }
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
