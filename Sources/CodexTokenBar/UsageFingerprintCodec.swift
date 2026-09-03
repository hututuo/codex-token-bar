import Foundation

enum UsageFingerprintCodecError: Error, Equatable {
    case invalidArity(Int)
    case unsupportedVersion(UInt8)
    case truncated
    case overflow
    case nonCanonical
    case trailingBytes
    case invalidBoolean(UInt64)
    case invalidLegacyText
    case invalidLegacyFixedWidth(Int)
}

/// Cross-platform exact token fingerprint encoding.
///
/// The canonical representation is one version byte followed by exactly
/// eleven unsigned LEB128 values. It is reversible and intentionally avoids
/// probabilistic hashing so SQLite uniqueness remains exact.
enum UsageFingerprintCodec {
    static let version: UInt8 = 1
    static let valueCount = 11
    static let legacyFixedWidthByteCount = valueCount * MemoryLayout<UInt64>.size

    static func encode(_ values: [UInt64]) throws -> Data {
        guard values.count == valueCount else {
            throw UsageFingerprintCodecError.invalidArity(values.count)
        }
        try validateFingerprintValues(values)
        var encoded = Data([version])
        encoded.reserveCapacity(1 + values.count * 2)
        for value in values {
            appendULEB128(value, to: &encoded)
        }
        return encoded
    }

    static func decode(_ encoded: Data) throws -> [UInt64] {
        guard let first = encoded.first else {
            throw UsageFingerprintCodecError.truncated
        }
        guard first == version else {
            throw UsageFingerprintCodecError.unsupportedVersion(first)
        }

        var offset = 1
        var values: [UInt64] = []
        values.reserveCapacity(valueCount)
        for _ in 0..<valueCount {
            values.append(try decodeULEB128(encoded, offset: &offset))
        }
        guard offset == encoded.count else {
            throw UsageFingerprintCodecError.trailingBytes
        }
        try validateFingerprintValues(values)
        return values
    }

    static func decodeLegacyText(_ encoded: String) throws -> [UInt64] {
        let fields = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == valueCount else {
            throw UsageFingerprintCodecError.invalidLegacyText
        }
        var values: [UInt64] = []
        values.reserveCapacity(valueCount)
        for field in fields {
            guard !field.isEmpty,
                  let value = UInt64(field),
                  field == String(value) else {
                throw UsageFingerprintCodecError.invalidLegacyText
            }
            values.append(value)
        }
        try validateFingerprintValues(values)
        return values
    }

    static func decodeLegacyFixedWidth(_ encoded: Data) throws -> [UInt64] {
        guard encoded.count == legacyFixedWidthByteCount else {
            throw UsageFingerprintCodecError.invalidLegacyFixedWidth(encoded.count)
        }
        var values: [UInt64] = []
        values.reserveCapacity(valueCount)
        for fieldIndex in 0..<valueCount {
            let start = fieldIndex * MemoryLayout<UInt64>.size
            var value: UInt64 = 0
            for byteIndex in 0..<MemoryLayout<UInt64>.size {
                value |= UInt64(encoded[start + byteIndex]) << UInt64(byteIndex * 8)
            }
            values.append(value)
        }
        try validateFingerprintValues(values)
        return values
    }

    private static func validateFingerprintValues(_ values: [UInt64]) throws {
        guard values[5] <= 1 else {
            throw UsageFingerprintCodecError.invalidBoolean(values[5])
        }
    }

    private static func appendULEB128(_ value: UInt64, to encoded: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            encoded.append(byte)
        } while remaining != 0
    }

    private static func decodeULEB128(
        _ encoded: Data,
        offset: inout Int
    ) throws -> UInt64 {
        var value: UInt64 = 0
        var shift = 0
        var byteCount = 0

        while true {
            guard offset < encoded.count else {
                throw UsageFingerprintCodecError.truncated
            }
            let byte = encoded[offset]
            offset += 1
            byteCount += 1
            let payload = UInt64(byte & 0x7F)

            guard shift < 64, shift != 63 || payload <= 1 else {
                throw UsageFingerprintCodecError.overflow
            }
            value |= payload << UInt64(shift)

            if byte & 0x80 == 0 {
                guard byteCount == 1 || payload != 0 else {
                    throw UsageFingerprintCodecError.nonCanonical
                }
                return value
            }
            guard byteCount < 10 else {
                throw UsageFingerprintCodecError.overflow
            }
            shift += 7
        }
    }
}
