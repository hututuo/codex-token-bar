import SharedSourceIO
import CZstd
import Darwin
import Foundation

/// Reads a compressed Codex session (`.jsonl.zst`, METRICS 5.3): one zstd stream of any number of frames, decompressed
/// from the start through bounded buffers and fed to the line splitter. Never tailed: a change of size, modification
/// time or identity reads it again from the start. Read-only, never follows symlinks.
struct CompressedStreamReader: Sendable {
    static let inputChunkBytes = 1 << 20

    let path: String
    let maxLineBytes: Int
    private var start: FileTailer.Start?
    private var lastStat: FileStat?

    init(path: String, start: FileTailer.Start = .beginning, maxLineBytes: Int = FileTailer.defaultMaxLineBytes) {
        self.path = path
        self.start = start
        self.maxLineBytes = maxLineBytes
    }

    /// A decoding error stops the file there and is reported once through `onMalformed`; lines before it stay.
    mutating func read(
        onReset: () -> Void,
        onMalformed: () -> Void,
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
        if let pending = start {
            start = nil
            if case .beginning = pending {} else {
                // Not read at startup: only a later change reads it.
                lastStat = stat
                return result
            }
        }
        if let lastStat, lastStat.size == stat.size, lastStat.modifiedNs == stat.modifiedNs, lastStat.identity == stat.identity {
            return result
        }
        if lastStat != nil {
            result.didReset = true
            onReset()
        }
        lastStat = stat
        guard let stream = ZSTD_createDStream() else {
            result.failed = true
            return result
        }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else {
            result.failed = true
            return result
        }

        let input = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.inputChunkBytes, alignment: 16)
        defer { input.deallocate() }
        let outputSize = ZSTD_DStreamOutSize()
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: outputSize, alignment: 16)
        defer { output.deallocate() }
        var lines = LineSplitter(maxLineBytes: maxLineBytes)
        var offset: Int64 = 0
        var frameOpen = false
        reading: while offset < stat.size {
            let wanted = Int(min(Int64(Self.inputChunkBytes), stat.size - offset))
            let count = SharedSourceIO.shared.pread(descriptor, into: UnsafeMutableRawBufferPointer(start: input.baseAddress, count: wanted), offset: offset)
            if count < 0 {
                if errno == EINTR { continue }
                result.failed = true
                break
            }
            if count == 0 { break }
            offset += Int64(count)
            result.bytesRead += count
            var source = ZSTD_inBuffer(src: input.baseAddress, size: count, pos: 0)
            var outputFull = false
            repeat {
                var target = ZSTD_outBuffer(dst: output.baseAddress, size: outputSize, pos: 0)
                let status = ZSTD_decompressStream(stream, &target, &source)
                if ZSTD_isError(status) != 0 {
                    onMalformed()
                    frameOpen = false
                    break reading
                }
                if target.pos > 0 {
                    lines.consume(UnsafeRawBufferPointer(rebasing: output[0..<target.pos]), onLine: onLine)
                }
                frameOpen = status != 0
                outputFull = target.pos == target.size
            } while source.pos < source.size || outputFull
        }
        // The stream ended inside a frame: truncated.
        if frameOpen, !result.failed { onMalformed() }
        return result
    }
}
