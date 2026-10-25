import Foundation

/// Why a protobuf buffer is malformed (METRICS 4.8).
enum ProtobufError: Error, Equatable {
    /// A varint, fixed-width value or length-delimited payload runs past the end of its buffer.
    case truncated
    /// A varint longer than 10 bytes.
    case overlongVarint
    case fieldNumberZero
    /// Wire types 3 and 4 (groups), 6 and 7.
    case unsupportedWireType(UInt8)
}

enum ProtobufWire: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// One field of a message. `payload` borrows the message's buffer.
struct ProtobufField {
    let number: UInt64
    let wire: ProtobufWire
    /// The value of a varint field; 0 for the other wire types.
    let varint: UInt64
    /// The bytes of a length-delimited field; empty for the other wire types.
    let payload: UnsafeRawBufferPointer
}

/// Validating reader of the fields of one message, in order. It never descends into nested messages.
struct ProtobufReader {
    private let bytes: UnsafeRawBufferPointer
    private var position = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    /// The next field, or nil at the end of the buffer.
    mutating func next() throws(ProtobufError) -> ProtobufField? {
        guard position < bytes.count else { return nil }
        let key = try Self.varint(bytes, at: &position)
        let number = key >> 3
        guard number != 0 else { throw .fieldNumberZero }
        let rawWire = UInt8(key & 7)
        guard let wire = ProtobufWire(rawValue: rawWire) else { throw .unsupportedWireType(rawWire) }
        var varint: UInt64 = 0
        var payload = UnsafeRawBufferPointer(start: nil, count: 0)
        switch wire {
        case .varint:
            varint = try Self.varint(bytes, at: &position)
        case .fixed64, .fixed32:
            let size = wire == .fixed64 ? 8 : 4
            guard size <= bytes.count - position else { throw .truncated }
            position += size
        case .lengthDelimited:
            let size = try Self.varint(bytes, at: &position)
            guard size <= UInt64(bytes.count - position) else { throw .truncated }
            payload = UnsafeRawBufferPointer(rebasing: bytes[position..<(position + Int(size))])
            position += Int(size)
        }
        return ProtobufField(number: number, wire: wire, varint: varint, payload: payload)
    }

    /// Decodes the varint at `position` (at most 10 bytes; bits above 64 are dropped) and moves past it.
    static func varint(_ bytes: UnsafeRawBufferPointer, at position: inout Int) throws(ProtobufError) -> UInt64 {
        var result: UInt64 = 0
        for group in 0..<10 {
            guard position < bytes.count else { throw .truncated }
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << (7 * group)
            if byte & 0x80 == 0 { return result }
        }
        throw .overlongVarint
    }
}

/// A message whose top-level fields are all valid (METRICS 4.8 wire format).
///
/// It borrows its buffer, so it must not outlive it. Accessors rescan the fields and filter by wire type: a known
/// field with an unexpected wire type is ignored. A nested message is validated only when it is read, and only the
/// occurrence that is read, so a malformed occurrence elsewhere goes unnoticed.
struct ProtobufMessage {
    private let bytes: UnsafeRawBufferPointer

    init(_ bytes: UnsafeRawBufferPointer) throws(ProtobufError) {
        var reader = ProtobufReader(bytes)
        while try reader.next() != nil {}
        self.bytes = bytes
    }

    var fields: Fields { Fields(reader: ProtobufReader(bytes)) }

    struct Fields: Sequence, IteratorProtocol {
        fileprivate var reader: ProtobufReader

        /// The buffer was validated, so reading cannot fail here.
        mutating func next() -> ProtobufField? { try? reader.next() }
    }

    func first(_ number: UInt64, wire: ProtobufWire) -> ProtobufField? {
        fields.first { $0.number == number && $0.wire == wire }
    }

    func last(_ number: UInt64, wire: ProtobufWire) -> ProtobufField? {
        var found: ProtobufField?
        for field in fields where field.number == number && field.wire == wire {
            found = field
        }
        return found
    }

    /// The last varint value of `number`, unsigned; 0 when absent.
    func uint(_ number: UInt64) -> UInt64 {
        last(number, wire: .varint)?.varint ?? 0
    }

    /// The last varint value of `number` reinterpreted as signed 64-bit (`int32`, `int64`, enums); 0 when absent.
    func int(_ number: UInt64) -> Int64 {
        Int64(bitPattern: uint(number))
    }

    /// The last (or first) string of `number`, invalid UTF-8 replaced by U+FFFD; empty when absent.
    func string(_ number: UInt64, first: Bool = false) -> String {
        guard let field = first ? self.first(number, wire: .lengthDelimited) : last(number, wire: .lengthDelimited)
        else { return "" }
        return String(decoding: field.payload, as: UTF8.self)
    }

    /// The last (or first) occurrence of a nested message, validated now; nil when absent.
    func message(_ number: UInt64, first: Bool = false) throws(ProtobufError) -> ProtobufMessage? {
        guard let field = first ? self.first(number, wire: .lengthDelimited) : last(number, wire: .lengthDelimited)
        else { return nil }
        return try ProtobufMessage(field.payload)
    }

    /// Every value of a repeated scalar, unpacked (wire type 0) and packed (wire type 2), in order.
    func repeatedUInt(_ number: UInt64) throws(ProtobufError) -> [UInt64] {
        var values: [UInt64] = []
        for field in fields where field.number == number {
            switch field.wire {
            case .varint:
                values.append(field.varint)
            case .lengthDelimited:
                var position = 0
                while position < field.payload.count {
                    values.append(try ProtobufReader.varint(field.payload, at: &position))
                }
            case .fixed64, .fixed32:
                break
            }
        }
        return values
    }

    /// The last `google.protobuf.Timestamp` of `number` in Unix milliseconds: `seconds * 1000 + nanos div 10^6`, with
    /// nanos outside 0 … 999 999 999 counted as 0. Nil when absent, when `seconds <= 0` and when the result does not
    /// fit in 64 bits.
    func timestampMs(_ number: UInt64) throws(ProtobufError) -> Int64? {
        guard let stamp = try message(number) else { return nil }
        let seconds = stamp.int(1)
        let nanos = stamp.int(2)
        guard seconds > 0 else { return nil }
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1000)
        let (total, carry) = whole.addingReportingOverflow((0...999_999_999).contains(nanos) ? nanos / 1_000_000 : 0)
        return overflow || carry ? nil : total
    }
}
