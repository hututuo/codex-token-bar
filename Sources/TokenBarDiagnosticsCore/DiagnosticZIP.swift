import Foundation

/// Small stored ZIPs avoid a runtime dependency and never embed local filenames.
enum DiagnosticZIP {
    static func encode(_ entries: [(String, Data)]) throws -> Data {
        var result = Data(), central = Data()
        func word<T: FixedWidthInteger>(_ value: T) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        for (name, bytes) in entries {
            guard !name.contains(".."), !name.hasPrefix("/"), bytes.count <= 8 * 1024 * 1024,
                  result.count + bytes.count <= 20 * 1024 * 1024 else { throw DiagnosticFiles.Failure.tooLarge }
            let filename = Data(name.utf8), offset = UInt32(result.count), size = UInt32(bytes.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            crc ^= 0xffffffff
            result.append(word(UInt32(0x04034b50))); result.append(word(UInt16(20)))
            result.append(word(UInt16(0x800))); result.append(word(UInt16(0)))
            result.append(word(UInt16(0))); result.append(word(UInt16(33)))
            result.append(word(crc)); result.append(word(size)); result.append(word(size))
            result.append(word(UInt16(filename.count))); result.append(word(UInt16(0)))
            result.append(filename); result.append(bytes)
            central.append(word(UInt32(0x02014b50))); central.append(word(UInt16(20))); central.append(word(UInt16(20)))
            central.append(word(UInt16(0x800))); central.append(word(UInt16(0)))
            central.append(word(UInt16(0))); central.append(word(UInt16(33)))
            central.append(word(crc)); central.append(word(size)); central.append(word(size))
            central.append(word(UInt16(filename.count)))
            for _ in 0..<4 { central.append(word(UInt16(0))) }
            central.append(word(UInt32(0))); central.append(word(offset)); central.append(filename)
        }
        let offset = UInt32(result.count)
        result.append(central); result.append(word(UInt32(0x06054b50)))
        result.append(word(UInt16(0))); result.append(word(UInt16(0)))
        result.append(word(UInt16(entries.count))); result.append(word(UInt16(entries.count)))
        result.append(word(UInt32(central.count))); result.append(word(offset)); result.append(word(UInt16(0)))
        return result
    }
}
