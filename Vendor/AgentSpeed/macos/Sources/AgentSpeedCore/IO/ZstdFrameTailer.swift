import CZstd
import Darwin
import Foundation

/// Reads complete lines from a file of independent zstd frames (METRICS 5.1), as DeepSeek Harness writes its sessions:
/// each append is one frame. Read-only, never follows symlinks.
struct ZstdFrameTailer: Sendable {
    static let maxFrameOutputBytes = 64 << 20
    /// Compressed bytes one frame may span; a larger frame cannot decode within `maxFrameOutputBytes`.
    static let maxFrameInputBytes = maxFrameOutputBytes + (1 << 20)
    private static let frameMagic: UInt32 = 0xFD2F_B528
    private static let skippableMagicMask: UInt32 = 0xFFFF_FFF0
    private static let skippableMagic: UInt32 = 0x184D_2A50
    private static let skippableHeaderBytes = 8
    /// No frame is shorter; fewer bytes at the offset always wait for more.
    private static let minimumFrameBytes = 8

    let path: String
    let maxFrameOutputBytes: Int
    /// Bytes taken from the file: decoded or skipped frames plus the buffered incomplete frame.
    private(set) var offset: Int64 = 0
    private(set) var identity: FileIdentity?
    /// The bytes at the offset were not a frame; reading skips ahead to the next frame magic (already counted as one
    /// malformed line).
    private(set) var isResynchronizing = false
    private var start: FileTailer.Start?
    /// Compressed bytes of the incomplete frame at the end of the file.
    private var pending: [UInt8] = []
    /// Remaining bytes of a skippable frame that have not been written or read yet.
    private var skipping: Int64 = 0
    private var lines: LineSplitter

    var oversizedLines: Int { lines.oversizedLines }

    /// `.tail` starts at the end, like `.end`: a frame stream cannot be entered in the middle.
    init(
        path: String,
        start: FileTailer.Start = .beginning,
        maxLineBytes: Int = FileTailer.defaultMaxLineBytes,
        maxFrameOutputBytes: Int = ZstdFrameTailer.maxFrameOutputBytes
    ) {
        self.path = path
        self.start = start
        self.maxFrameOutputBytes = max(1, maxFrameOutputBytes)
        lines = LineSplitter(maxLineBytes: maxLineBytes)
    }

    /// Decodes every complete frame appended since the last call. A frame that fails to decode, or bytes that are not a
    /// frame at all, are skipped and reported once through `onMalformed`; an incomplete trailing frame waits for its
    /// remaining bytes.
    mutating func read(
        onReset: () -> Void = {},
        onMalformed: () -> Void = {},
        onReadBoundary: (SourceReadBoundary) -> Void = { _ in },
        onLine: (UnsafeRawBufferPointer) -> Void
    ) -> FileTailer.ReadResult {
        var result = FileTailer.ReadResult()
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
        if let pendingStart = start {
            switch pendingStart {
            case .beginning: offset = 0
            case .end(let recordedSize): offset = min(recordedSize, stat.size)
            case .tail: offset = stat.size
            }
            start = nil
        }

        var decoder: ZstdFrameDecoder?
        var reportedBoundary = false
        while offset < stat.size {
            if skipping > 0 {
                let skipped = min(skipping, stat.size - offset)
                offset += skipped
                skipping -= skipped
                result.bytesRead += Int(skipped)
                continue
            }
            let wanted = Int(min(Int64(FileTailer.chunkBytes), stat.size - offset))
            let count = appendPending(from: descriptor, count: wanted)
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
            offset += Int64(count)
            result.bytesRead += count
            drainFrames(decoder: &decoder, onMalformed: onMalformed, onLine: onLine)
        }
        return result
    }

    /// Forgets everything; the next read starts at offset 0.
    mutating func restart() {
        offset = 0
        pending = []
        skipping = 0
        isResynchronizing = false
        lines.reset()
        start = nil
    }

    private mutating func appendPending(from descriptor: Int32, count: Int) -> Int {
        let previous = pending.count
        pending.append(contentsOf: repeatElement(0, count: count))
        let offset = self.offset
        let read = pending.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress! + previous, count, off_t(offset))
        }
        pending.removeLast(count - max(read, 0))
        return read
    }

    /// Decodes the complete frames at the start of `pending` and keeps the incomplete rest.
    private mutating func drainFrames(
        decoder: inout ZstdFrameDecoder?,
        onMalformed: () -> Void,
        onLine: (UnsafeRawBufferPointer) -> Void
    ) {
        var bytes: [UInt8] = []
        swap(&bytes, &pending)
        var cursor = 0
        bytes.withUnsafeBytes { buffer in
            while cursor < buffer.count {
                if isResynchronizing {
                    guard let next = Self.nextMagic(in: buffer, from: cursor) else {
                        // A magic may straddle the end of what has been written so far.
                        cursor = max(cursor, buffer.count - 3)
                        return
                    }
                    cursor = next
                    isResynchronizing = false
                }
                let frame = UnsafeRawBufferPointer(rebasing: buffer[cursor...])
                guard frame.count >= Self.minimumFrameBytes else { return }
                if UInt32(littleEndian: frame.loadUnaligned(as: UInt32.self)) & Self.skippableMagicMask == Self.skippableMagic {
                    let total = Int64(Self.skippableHeaderBytes)
                        + Int64(UInt32(littleEndian: frame.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
                    if Int64(frame.count) >= total {
                        cursor += Int(total)
                    } else {
                        skipping = total - Int64(frame.count)
                        cursor = buffer.count
                    }
                    continue
                }
                let size = ZSTD_findFrameCompressedSize(frame.baseAddress, frame.count)
                let incomplete = ZSTD_isError(size) != 0 && ZSTD_getErrorCode(size) == ZSTD_error_srcSize_wrong
                if incomplete, frame.count <= Self.maxFrameInputBytes { return }
                guard ZSTD_isError(size) == 0, size > 0 else {
                    // Not a frame (unknown magic, invalid block header) or one too large to ever decode.
                    onMalformed()
                    isResynchronizing = true
                    cursor += 1
                    continue
                }
                if decoder == nil { decoder = ZstdFrameDecoder() }
                let decoded = decoder?.decode(UnsafeRawBufferPointer(rebasing: frame[0..<size]), limit: maxFrameOutputBytes) {
                    lines.consume($0, onLine: onLine)
                } ?? false
                if !decoded { onMalformed() }
                cursor += size
            }
        }
        if cursor >= bytes.count {
            bytes.removeAll(keepingCapacity: bytes.capacity <= 1 << 20)
        } else if cursor > 0 {
            bytes.removeFirst(cursor)
        }
        swap(&bytes, &pending)
    }

    /// Position of the next zstd frame magic or skippable-frame magic at or after `start`.
    private static func nextMagic(in buffer: UnsafeRawBufferPointer, from start: Int) -> Int? {
        var index = start
        while index + 4 <= buffer.count {
            let word = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt32.self))
            if word == frameMagic || word & skippableMagicMask == skippableMagic { return index }
            index += 1
        }
        return nil
    }
}
