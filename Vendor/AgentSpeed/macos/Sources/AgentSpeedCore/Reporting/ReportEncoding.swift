import CryptoKit
import Foundation

/// Unpadded base64url (RFC 4648 §5) as REPORTING 5.2 requires it: canonical, no padding, zero trailing bits.
public enum Base64URL {
    public static func encode<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil for another alphabet, padding, a length of 1 mod 4 or non-zero trailing bits.
    public static func decode(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 4 != 1, bytes.allSatisfy(isAlphabet) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - bytes.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }

    private static func isAlphabet(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }
}

enum ReportHash {
    /// SHA-256 as 64 lower-case hexadecimal digits (REPORTING 5.3 line 8).
    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// `YYYY-MM-DDTHH:MM:SS.sssZ` in UTC (REPORTING 6.3 `sentAt`).
public enum ReportInstant {
    public static func format(unixMs: Int64) -> String {
        let seconds = unixMs >= 0 ? unixMs / 1000 : (unixMs - 999) / 1000
        let millis = unixMs - seconds * 1000
        let day = UTCDay(ms: seconds * 1000)
        let secondOfDay = day.msOfDay / 1000
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(day.label)T\(pad(secondOfDay / 3600, 2)):\(pad(secondOfDay / 60 % 60, 2)):\(pad(secondOfDay % 60, 2))."
            + "\(pad(millis, 3))Z"
    }
}
