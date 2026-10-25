import Darwin
import Foundation

/// The session header of an omp file whose reading starts past its beginning (METRICS 4.7). Read-only, never follows
/// symlinks.
enum OmpHeader {
    private static let chunkBytes = 64 << 10

    /// The bytes of the first line of type `session` among the first two lines of the file, without the newline.
    /// Lines are taken like Python's `readline(maxLineBytes)`: a longer line counts as several, and an unterminated
    /// last line counts too.
    static func headerLine(atPath path: String, maxLineBytes: Int) -> [UInt8]? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard let stat = FileStat.fstat(descriptor), stat.isRegularFile else { return nil }
        var offset: Int64 = 0
        for _ in 0..<2 {
            guard var line = readLine(descriptor, offset: &offset, limit: max(1, maxLineBytes)) else { return nil }
            if line.last == UInt8(ascii: "\n") { line.removeLast() }
            let isHeader = line.withUnsafeBytes { bytes in
                if case .line(.header) = OmpLineExtractor.extract(bytes) { return true }
                return false
            }
            if isHeader { return line }
        }
        return nil
    }

    /// At most `limit` bytes, through the next newline. Nil at the end of the file or on a read error.
    private static func readLine(_ descriptor: Int32, offset: inout Int64, limit: Int) -> [UInt8]? {
        var line: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: min(chunkBytes, limit))
        while line.count < limit {
            let wanted = min(chunk.count, limit - line.count)
            let position = offset
            let count = chunk.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, wanted, off_t(position)) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard count > 0 else { break }
            if let newline = chunk[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[0...newline])
                offset += Int64(newline + 1)
                return line
            }
            line.append(contentsOf: chunk[0..<count])
            offset += Int64(count)
        }
        return line.isEmpty ? nil : line
    }
}
