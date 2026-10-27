import SharedSourceIO
import Foundation

extension FileHandle {
    /// Shares physical bytes, not FileHandle's logical position, across the
    /// accounting, activity and completed-body consumers.
    func readShared(upToCount count: Int, probe: Bool = false) throws -> Data {
        let offset = try self.offset()
        guard offset <= UInt64(Int64.max) else { throw CocoaError(.fileReadTooLarge) }
        var result = Data()
        while result.count < count {
            let bytes = try SharedSourceIO.shared.read(descriptor: fileDescriptor,
                offset: Int64(offset) + Int64(result.count), count: count - result.count, probe: probe)
            if bytes.isEmpty { break }
            result.append(bytes)
        }
        try seek(toOffset: offset + UInt64(result.count))
        return result
    }
    static func readSourceDocument(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let before = try SourceFileObservation.readPhysical(handle: handle)
        guard before.size <= UInt64(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        let data = try handle.readShared(upToCount: Int(before.size))
        guard data.count == before.size,
              before.matches(try SourceFileObservation.readPhysical(handle: handle)),
              before.matches(try SourceFileObservation.read(at: url)) else { throw POSIXError(.ESTALE) }
        return data
    }
    func readToEndShared() throws -> Data {
        var result = Data()
        while true {
            let bytes = try readShared(upToCount:4*1024*1024)
            if bytes.isEmpty { return result }
            result.append(bytes)
        }
    }
}
