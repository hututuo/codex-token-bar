import Foundation
import SQLite3

/// Private, versioned numerical-stage rows. Never route them through JSON,
/// JavaScript Number, local date strings, or lossy TEXT conversion.
enum ExactStageRowCodec {
    static let version = 1
    static let maximumRowBytes = 16 * 1_024 * 1_024
    private static let magic: [UInt8] = [0x54, 0x42, 0x52, 0x01]

    enum Failure: Error { case invalidRow }

    static func encode(_ row: SQLiteStatement) throws -> Data {
        guard (1...64).contains(row.columnCount) else { throw Failure.invalidRow }
        var result = Data(magic)
        var columns = UInt32(row.columnCount).bigEndian
        withUnsafeBytes(of: &columns) { result.append(contentsOf: $0) }
        for column in 0..<row.columnCount {
            let value = row.canonicalBytes(column)
            guard value.count <= maximumRowBytes - result.count else { throw Failure.invalidRow }
            result.append(value)
        }
        return result
    }

    static func decode(_ row: Data, expectedColumns: Int) throws -> [SQLiteBinding] {
        guard (1...64).contains(expectedColumns), row.count >= 8,
              row.count <= maximumRowBytes, Array(row.prefix(4)) == magic else {
            throw Failure.invalidRow
        }
        // Bounds are checked before every read and before allocating payloads.
        var position = 4
        func unsigned(_ count: Int) throws -> UInt64 {
            guard count <= row.count - position else { throw Failure.invalidRow }
            var value: UInt64 = 0
            for _ in 0..<count { value = (value << 8) | UInt64(row[row.startIndex + position]); position += 1 }
            return value
        }
        guard try unsigned(4) == UInt64(expectedColumns) else { throw Failure.invalidRow }
        var result: [SQLiteBinding] = []
        result.reserveCapacity(expectedColumns)
        for _ in 0..<expectedColumns {
            let type = try unsigned(1)
            let count = try unsigned(8)
            guard count <= UInt64(row.count - position) else { throw Failure.invalidRow }
            switch Int32(type) {
            case SQLITE_NULL:
                guard count == 0 else { throw Failure.invalidRow }
                result.append(.null)
            case SQLITE_INTEGER:
                guard count == 8 else { throw Failure.invalidRow }
                result.append(.int64(Int64(bitPattern: try unsigned(8))))
            case SQLITE_FLOAT:
                guard count == 8 else { throw Failure.invalidRow }
                result.append(.double(Double(bitPattern: try unsigned(8))))
            case SQLITE_TEXT, SQLITE_BLOB:
                let end = position + Int(count)
                let payload = Data(row[(row.startIndex + position)..<(row.startIndex + end)])
                result.append(Int32(type) == SQLITE_TEXT ? .textBytes(payload) : .blob(payload))
                position = end
            default:
                throw Failure.invalidRow
            }
        }
        guard position == row.count else { throw Failure.invalidRow }
        return result
    }
}
