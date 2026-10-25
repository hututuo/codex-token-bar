import Darwin
import Foundation

/// Wall and monotonic clocks captured at a local source-read boundary.
struct SourceReadBoundary: Equatable, Sendable {
    let observedAtMs: Int64
    let observedTickMs: Int64

    static func now() -> SourceReadBoundary {
        SourceReadBoundary(
            observedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            observedTickMs: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        )
    }
}

/// Reads complete lines appended to one file (METRICS 5). Read-only, never follows symlinks.
struct FileTailer: Sendable {
    static let defaultMaxLineBytes = 32 << 20
    static let chunkBytes = 4 << 20
    /// Files larger than this are seeded from their last `tailWindowBytes` only.
    static let largeFileBytes: Int64 = 256 << 20
    static let tailWindowBytes: Int64 = 64 << 20

    enum Start: Equatable, Sendable {
        case beginning
        /// Start at the given size; an unterminated last line there is skipped.
        case end(Int64)
        /// Start `bytes` before the end, aligned to the next newline.
        case tail(Int64)
    }

    struct ReadResult: Equatable, Sendable {
        var bytesRead = 0
        /// Time at which the first bytes or rows crossed into the local reader.
        var readBoundary: SourceReadBoundary?
        /// The file shrank or was replaced; offset and parser state must restart.
        var didReset = false
        var failed = false
        var stat: FileStat?
        /// A whole-document file over its size limit was not read (`partialHistory`).
        var oversized = false

        mutating func recordReadBoundary(onReadBoundary: (SourceReadBoundary) -> Void) {
            guard readBoundary == nil else { return }
            let boundary = SourceReadBoundary.now()
            readBoundary = boundary
            onReadBoundary(boundary)
        }
    }

    let path: String
    private(set) var offset: Int64 = 0
    private(set) var identity: FileIdentity?
    private var start: Start?
    private var lines: LineSplitter

    var maxLineBytes: Int { lines.maxLineBytes }
    var oversizedLines: Int { lines.oversizedLines }

    init(path: String, start: Start = .beginning, maxLineBytes: Int = FileTailer.defaultMaxLineBytes) {
        self.path = path
        self.start = start
        lines = LineSplitter(maxLineBytes: maxLineBytes)
    }

    /// Reads every complete line appended since the last call.
    mutating func read(
        onReset: () -> Void = {},
        onReadBoundary: (SourceReadBoundary) -> Void = { _ in },
        onLine: (UnsafeRawBufferPointer) -> Void
    ) -> ReadResult {
        var result = ReadResult()
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            result.failed = true
            return result
        }
        defer { Darwin.close(descriptor) }
        guard let stat = FileStat.fstat(descriptor), stat.isRegularFile else {
            result.failed = true
            return result
        }
        result.stat = stat

        if let identity, identity != stat.identity || stat.size < offset {
            restart()
            result.didReset = true
            onReset()
        }
        identity = stat.identity
        if let pending = start {
            position(at: pending, size: stat.size, descriptor: descriptor)
            start = nil
        }
        guard offset < stat.size else { return result }

        let capacity = Int(min(Int64(Self.chunkBytes), stat.size - offset))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var reportedBoundary = false
        while offset < stat.size {
            let wanted = Int(min(Int64(capacity), stat.size - offset))
            let count = Darwin.pread(descriptor, buffer.baseAddress, wanted, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                result.failed = true
                break
            }
            if count == 0 { break }
            if !reportedBoundary {
                result.recordReadBoundary(onReadBoundary: onReadBoundary)
                reportedBoundary = true
            }
            lines.consume(UnsafeRawBufferPointer(rebasing: buffer[0..<count]), onLine: onLine)
            offset += Int64(count)
            result.bytesRead += count
        }
        return result
    }

    /// Forgets everything; the next read starts at offset 0.
    mutating func restart() {
        offset = 0
        lines.reset()
        start = nil
    }

    private mutating func position(at start: Start, size: Int64, descriptor: Int32) {
        switch start {
        case .beginning:
            offset = 0
        case .end(let recordedSize):
            offset = min(recordedSize, size)
            if offset > 0 {
                var last: UInt8 = 0
                if Darwin.pread(descriptor, &last, 1, off_t(offset - 1)) == 1, last != 0x0A {
                    lines.skipToNextNewline()
                }
            }
        case .tail(let window):
            if size > window {
                offset = size - window
                lines.skipToNextNewline()
            } else {
                offset = 0
            }
        }
    }
}
