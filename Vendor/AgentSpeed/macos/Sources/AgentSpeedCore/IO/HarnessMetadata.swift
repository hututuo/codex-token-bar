import Darwin
import Foundation

enum HarnessMetadata {
    static func read(_ path: String, maxBytes: Int64 = 1 << 20) -> JSONValue? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard let stat = FileStat.fstat(descriptor), stat.isRegularFile, stat.size >= 0, stat.size <= maxBytes else { return nil }
        var data = Data(count: Int(stat.size))
        let read = data.withUnsafeMutableBytes { bytes in
            Darwin.pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard read == data.count else { return nil }
        return try? JSONParser.parse(data)
    }
}
