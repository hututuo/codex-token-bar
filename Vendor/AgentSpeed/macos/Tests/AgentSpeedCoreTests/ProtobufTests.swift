import Foundation
import Testing
@testable import AgentSpeedCore

/// A tiny protobuf encoder, mirroring the one of `spec/tools/antigravity_fixtures.py`.
enum ProtobufEncoder {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    /// Negative values become ten-byte two's complement varints.
    static func varint(signed value: Int64) -> [UInt8] {
        varint(UInt64(bitPattern: value))
    }

    static func key(_ field: UInt64, _ wire: UInt8) -> [UInt8] {
        varint(field << 3 | UInt64(wire))
    }

    /// Omitted when zero, as proto3 writes it.
    static func int(_ field: UInt64, _ value: Int64) -> [UInt8] {
        value == 0 ? [] : key(field, 0) + varint(signed: value)
    }

    static func uint(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        value == 0 ? [] : key(field, 0) + varint(value)
    }

    static func bytes(_ field: UInt64, _ data: [UInt8]) -> [UInt8] {
        key(field, 2) + varint(UInt64(data.count)) + data
    }

    /// Omitted when empty.
    static func string(_ field: UInt64, _ text: String) -> [UInt8] {
        text.isEmpty ? [] : bytes(field, Array(text.utf8))
    }

    static func message(_ field: UInt64, _ parts: [UInt8]...) -> [UInt8] {
        bytes(field, parts.flatMap { $0 })
    }

    static func packed(_ field: UInt64, _ values: [UInt64]) -> [UInt8] {
        bytes(field, values.flatMap { varint($0) })
    }

    static func fixed32(_ field: UInt64, _ value: UInt32) -> [UInt8] {
        key(field, 5) + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func fixed64(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        key(field, 1) + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

@Suite("Protobuf")
struct ProtobufTests {
    typealias PB = ProtobufEncoder

    struct VarintRead: Equatable {
        var value: UInt64
        var length: Int
    }

    static func varint(_ bytes: [UInt8]) -> Result<VarintRead, ProtobufError> {
        bytes.withUnsafeBytes { buffer in
            var position = 0
            do throws(ProtobufError) {
                let value = try ProtobufReader.varint(buffer, at: &position)
                return .success(VarintRead(value: value, length: position))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Validates `bytes` as a message, then reads it with `body`.
    static func read<T>(_ bytes: [UInt8], _ body: (ProtobufMessage) throws -> T) -> Result<T, ProtobufError> {
        bytes.withUnsafeBytes { buffer in
            do {
                return .success(try body(try ProtobufMessage(buffer)))
            } catch let error as ProtobufError {
                return .failure(error)
            } catch {
                preconditionFailure("unexpected \(error)")
            }
        }
    }

    static func error(_ bytes: [UInt8]) -> ProtobufError? {
        if case .failure(let error) = read(bytes, { _ in () }) { return error }
        return nil
    }

    // MARK: - Varints

    @Test func varintsDecode() {
        let cases: [([UInt8], UInt64, Int)] = [
            ([0x00], 0, 1),
            ([0x01], 1, 1),
            ([0x7F], 127, 1),
            ([0x80, 0x01], 128, 2),
            ([0xAC, 0x02], 300, 2),
            ([0x80, 0x00], 0, 2),
            ([0x05, 0xFF], 5, 1),
            (PB.varint(UInt64(UInt32.max)), UInt64(UInt32.max), 5),
            ([UInt8](repeating: 0xFF, count: 9) + [0x01], .max, 10),
            ([UInt8](repeating: 0xFF, count: 9) + [0x7F], .max, 10),
            ([UInt8](repeating: 0x80, count: 9) + [0x02], 0, 10),
        ]
        for (bytes, value, length) in cases {
            #expect(Self.varint(bytes) == .success(VarintRead(value: value, length: length)), "\(bytes)")
        }
        #expect(PB.varint(.max).count == 10)
        #expect(Self.varint(PB.varint(1 << 63)) == .success(VarintRead(value: 1 << 63, length: 10)))
    }

    @Test func varintErrors() {
        #expect(Self.varint([]) == .failure(.truncated))
        #expect(Self.varint([0x80]) == .failure(.truncated))
        #expect(Self.varint([0xFF, 0xFF]) == .failure(.truncated))
        #expect(Self.varint([UInt8](repeating: 0xFF, count: 9)) == .failure(.truncated))
        #expect(Self.varint([UInt8](repeating: 0xFF, count: 10) + [0x01]) == .failure(.overlongVarint))
        #expect(Self.varint([UInt8](repeating: 0x80, count: 10)) == .failure(.overlongVarint))
        #expect(Self.error(PB.key(1, 0) + [UInt8](repeating: 0x80, count: 10) + [0x00]) == .overlongVarint)
        #expect(Self.error(PB.key(1, 0)) == .truncated)
        #expect(Self.error([0x80]) == .truncated)
    }

    @Test func signedReinterpretation() {
        let minusOne = PB.int(1, -1)
        #expect(minusOne.count == 11)
        let message = minusOne + PB.int(2, -5) + PB.int(3, .min) + PB.uint(4, 1 << 63) + PB.int(5, 7)
        let values = Self.read(message) { message in
            [message.int(1), message.int(2), message.int(3), message.int(4), message.int(5)]
        }
        #expect(values == .success([-1, -5, .min, .min, 7]))
        #expect(Self.read(message) { $0.uint(1) } == .success(.max))
        #expect(Self.read(message) { $0.uint(2) } == .success(UInt64(bitPattern: -5)))
    }

    // MARK: - Fields

    @Test func fixedWidthFieldsAreSkipped() {
        let message = PB.fixed64(1, 0x0123_4567_89AB_CDEF) + PB.fixed32(2, 7) + PB.uint(1, 42) + PB.fixed64(1, 99)
            + PB.fixed32(3, 1) + PB.string(4, "after")
        #expect(Self.read(message) { $0.uint(1) } == .success(42))
        #expect(Self.read(message) { $0.uint(2) } == .success(0))
        #expect(Self.read(message) { $0.string(4) } == .success("after"))
        #expect(Self.error(PB.key(1, 1) + [UInt8](repeating: 0, count: 7)) == .truncated)
        #expect(Self.error(PB.key(1, 5) + [0, 0, 0]) == .truncated)
        #expect(Self.error(PB.key(1, 5) + [0, 0, 0, 0]) == nil)
    }

    @Test func unknownFieldsOfEveryValidWireTypeAreSkipped() {
        let unknown = PB.uint(9001, 77) + PB.fixed64(9002, .max) + PB.bytes(9003, [0x0F, 0xFF, 0x07])
            + PB.fixed32(9004, 3) + PB.uint((1 << 29) - 1, 1) + PB.uint(1 << 60, 1) + PB.bytes(1 << 61 - 1, [])
        let message = unknown + PB.string(1, "known") + unknown
        #expect(Self.read(message) { $0.string(1) } == .success("known"))
        #expect(Self.read(message) { $0.fields.reduce(0) { count, _ in count + 1 } } == .success(15))
    }

    @Test(arguments: [3, 4, 6, 7] as [UInt8])
    func groupAndReservedWireTypesAreMalformed(wire: UInt8) {
        #expect(Self.error(PB.key(5, wire)) == .unsupportedWireType(wire))
        #expect(Self.error(PB.uint(1, 1) + PB.key(5, wire) + [0x00]) == .unsupportedWireType(wire))
        #expect(Self.error(PB.string(1, "x") + PB.key(5, wire)) == .unsupportedWireType(wire))
    }

    @Test func fieldNumberZeroIsMalformed() {
        #expect(Self.error([0x00]) == .fieldNumberZero)
        #expect(Self.error([0x00, 0x01]) == .fieldNumberZero)
        #expect(Self.error([0x02, 0x00]) == .fieldNumberZero)
        #expect(Self.error([0x07]) == .fieldNumberZero)
        #expect(Self.error(PB.uint(1, 1) + [0x00, 0x00]) == .fieldNumberZero)
    }

    @Test func lengthPastEndIsMalformed() {
        #expect(Self.error(PB.key(1, 2) + PB.varint(4) + [1, 2, 3]) == .truncated)
        #expect(Self.error(PB.key(1, 2) + PB.varint(3) + [1, 2, 3]) == nil)
        #expect(Self.error(PB.key(1, 2) + PB.varint(.max) + [1]) == .truncated)
        #expect(Self.error(PB.key(1, 2) + PB.varint(1 << 62)) == .truncated)
        #expect(Self.error(PB.key(1, 2) + [0x80]) == .truncated)
        #expect(Self.error(PB.key(1, 2)) == .truncated)
        #expect(Self.error(PB.string(1, "ok") + PB.key(2, 2) + PB.varint(1)) == .truncated)
    }

    @Test func lastOccurrenceWinsAndFirstWhereAsked() {
        let message = PB.uint(1, 1) + PB.uint(1, 2) + PB.string(2, "a") + PB.string(2, "b")
            + PB.message(3, PB.uint(1, 5)) + PB.message(3, PB.uint(1, 6))
        #expect(Self.read(message) { $0.uint(1) } == .success(2))
        #expect(Self.read(message) { $0.string(2) } == .success("b"))
        #expect(Self.read(message) { $0.string(2, first: true) } == .success("a"))
        #expect(Self.read(message) { try $0.message(3)?.uint(1) } == .success(6))
        #expect(Self.read(message) { try $0.message(3, first: true)?.uint(1) } == .success(5))
        #expect(Self.read(message) { $0.first(1, wire: .varint)?.varint } == .success(1))
        #expect(Self.read(message) { $0.last(1, wire: .varint)?.varint } == .success(2))
    }

    @Test func knownFieldWithWrongWireTypeIsIgnored() {
        let message = PB.string(1, "x") + PB.uint(2, 5) + PB.uint(3, 1_761_000_000) + PB.fixed32(4, 9)
            + PB.fixed64(5, 9) + PB.uint(6, 7) + PB.string(6, "six")
        #expect(Self.read(message) { $0.uint(1) } == .success(0))
        #expect(Self.read(message) { $0.string(2) } == .success(""))
        #expect(Self.read(message) { try $0.message(2) == nil } == .success(true))
        #expect(Self.read(message) { try $0.timestampMs(3) } == .success(nil))
        #expect(Self.read(message) { $0.uint(4) } == .success(0))
        #expect(Self.read(message) { $0.string(5) } == .success(""))
        #expect(Self.read(message) { $0.uint(6) } == .success(7))
        #expect(Self.read(message) { $0.string(6) } == .success("six"))
    }

    @Test func repeatedScalarsArePackedOrUnpacked() {
        let message = PB.uint(2, 3) + PB.packed(2, [1, 300, .max]) + PB.key(2, 0) + [0x00] + PB.fixed32(2, 9)
            + PB.packed(2, []) + PB.uint(3, 8) + PB.uint(2, 4)
        #expect(Self.read(message) { try $0.repeatedUInt(2) } == .success([3, 1, 300, .max, 0, 4]))
        #expect(Self.read(message) { try $0.repeatedUInt(9) } == .success([]))
    }

    @Test func malformedPackedPayloadIsMalformedWhenRead() {
        for payload: [UInt8] in [[0x80], [0x01, 0x80], [UInt8](repeating: 0xFF, count: 10) + [0x01]] {
            let message = PB.packed(2, [1]) + PB.bytes(2, payload)
            #expect(Self.error(message) == nil)
            #expect(throws: ProtobufError.self) { try Self.read(message) { try $0.repeatedUInt(2) }.get() }
            #expect(Self.read(message) { try $0.repeatedUInt(3) } == .success([]))
        }
    }

    @Test func nestedMessageIsValidatedOnlyWhenRead() {
        let bad: [UInt8] = [0x0F]  // field 1, wire type 7
        let message = PB.bytes(3, bad) + PB.message(4, PB.uint(1, 9))
        #expect(Self.error(message) == nil)
        #expect(Self.read(message) { try $0.message(4)?.uint(1) } == .success(9))
        #expect(Self.read(message) { try $0.message(3) == nil } == .failure(.unsupportedWireType(7)))
        #expect(Self.read(message) { try $0.timestampMs(3) } == .failure(.unsupportedWireType(7)))
        #expect(Self.read(message) { $0.string(3) } == .success("\u{0F}"))

        let badFirst = PB.bytes(1, bad) + PB.message(1, PB.uint(1, 2))
        #expect(Self.read(badFirst) { try $0.message(1)?.uint(1) } == .success(2))
        #expect(Self.read(badFirst) { try $0.message(1, first: true)?.uint(1) } == .failure(.unsupportedWireType(7)))
        let badLast = PB.message(1, PB.uint(1, 2)) + PB.bytes(1, [0x0A, 0x05])
        #expect(Self.read(badLast) { try $0.message(1, first: true)?.uint(1) } == .success(2))
        #expect(Self.read(badLast) { try $0.message(1)?.uint(1) } == .failure(.truncated))
    }

    @Test func emptyMessageHasDefaults() throws {
        let check = { (message: ProtobufMessage) throws(ProtobufError) -> Bool in
            let nested = try message.message(1)
            let stamp = try message.timestampMs(1)
            let repeated = try message.repeatedUInt(1)
            return message.uint(1) == 0 && message.int(1) == 0 && message.string(1).isEmpty && nested == nil
                && stamp == nil && repeated.isEmpty && message.first(1, wire: .varint) == nil
        }
        #expect(Self.read([], check) == .success(true))
        let empty = try ProtobufMessage(UnsafeRawBufferPointer(start: nil, count: 0))
        #expect(try check(empty))
        #expect(Self.read(PB.bytes(1, [])) { try $0.message(1).map { $0.uint(1) } } == .success(0))
    }

    @Test func timestamps() {
        let limit = Int64.max / 1000
        let cases: [(seconds: Int64, nanos: Int64, ms: Int64?)] = [
            (1_761_000_000, 123_456_789, 1_761_000_000_123),
            (1, 999_999, 1000),
            (1, 1_000_000, 1001),
            (1, 999_999_999, 1999),
            (1, 1_000_000_000, 1000),
            (1, 1_999_999_999, 1000),
            (1, -1, 1000),
            (1, .min, 1000),
            (0, 5_000_000, nil),
            (-1, 0, nil),
            (.min, 0, nil),
            (limit, 807_000_000, .max),
            (limit, 808_000_000, nil),
            (limit + 1, 0, nil),
            (.max, 0, nil),
        ]
        for (seconds, nanos, ms) in cases {
            let message = PB.message(1, PB.int(1, seconds), PB.int(2, nanos))
            #expect(Self.read(message) { try $0.timestampMs(1) } == .success(ms), "\(seconds) s \(nanos) ns")
        }
        #expect(Self.read(PB.message(1)) { try $0.timestampMs(1) } == .success(nil))
        #expect(Self.read([]) { try $0.timestampMs(1) } == .success(nil))
        let repeated = PB.message(1, PB.int(1, 5)) + PB.message(1, PB.int(1, 7))
        #expect(Self.read(repeated) { try $0.timestampMs(1) } == .success(7000))
    }
}
