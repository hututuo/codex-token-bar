import Darwin
import Foundation

/// Reuses one fixed buffer for long sequential reads. `FileHandle.readData`
/// creates a new Foundation `Data` object for every chunk; multi-gigabyte
/// history rebuilds can leave those allocations resident in malloc's dirty
/// regions even after the objects are released.
struct CodexBoundedFileReader {
    static let defaultBufferSize = 64 * 1_024

    private var storage: [UInt8]

    init(bufferSize: Int = defaultBufferSize) {
        precondition(bufferSize > 0)
        storage = [UInt8](repeating: 0, count: bufferSize)
    }

    var capacity: Int {
        storage.count
    }

    mutating func read(
        from handle: any CodexReadHandle,
        upToCount requestedCount: Int,
        file: URL,
        body: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int {
        precondition(requestedCount >= 0 && requestedCount <= storage.count)
        guard requestedCount > 0 else { return 0 }

        let count = try storage.withUnsafeMutableBytes { bytes in
            try handle.readBytes(into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<requestedCount]))
        }

        if count > 0 {
            try storage.withUnsafeBytes { bytes in
                try body(UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            }
        }
        return count
    }
}
