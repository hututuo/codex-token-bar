import CZstd
import Foundation

/// Reads complete independent DSH zstd frames without temporary files or source mutation.
/// A checkpoint only advances at a frame ending on a JSONL boundary.
enum MultiClientCompressedUsageReader {
    struct Batch { let data: Data; let consumed: Int }
    enum Failure: LocalizedError {
        case corrupt, oversized
        var errorDescription: String? {
            switch self {
            case .corrupt: "压缩日志帧损坏，已保留读取断点"
            case .oversized: "压缩日志单帧或未完成行超过安全上限，已保留读取断点"
            }
        }
    }
    static func decode(_ input: Data, maximumDecoded: Int = 16 * 1024 * 1024) throws -> Batch {
        var cursor = 0, committed = 0, committedBytes = 0
        var decoded = Data()
        while cursor < input.count {
            let tail = input.dropFirst(cursor)
            let frameSize = tail.withUnsafeBytes { ZSTD_findFrameCompressedSize($0.baseAddress, $0.count) }
            if ZSTD_isError(frameSize) != 0 {
                // Incomplete final frames are expected while the harness is appending.
                if ZSTD_getErrorCode(frameSize) == ZSTD_error_srcSize_wrong { break }
                throw Failure.corrupt
            }
            guard frameSize > 0, frameSize <= tail.count else { throw Failure.corrupt }
            guard let stream = ZSTD_createDStream() else { throw Failure.corrupt }
            defer { ZSTD_freeDStream(stream) }
            let initialized = ZSTD_initDStream(stream)
            guard ZSTD_isError(initialized) == 0 else { throw Failure.corrupt }
            // Bound window allocation as well as emitted output for hostile/corrupt headers.
            let configured = ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 24)
            guard ZSTD_isError(configured) == 0 else { throw Failure.corrupt }
            let frame = Data(tail.prefix(frameSize))
            try frame.withUnsafeBytes { bytes in
                var source = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
                var output = [UInt8](repeating: 0, count: 64 * 1024)
                var remaining = 1
                while source.pos < source.size || remaining != 0 {
                    let previous = source.pos
                    var count = 0
                    remaining = output.withUnsafeMutableBytes { destination in
                        var target = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                        let result = ZSTD_decompressStream(stream, &target, &source)
                        count = target.pos
                        return result
                    }
                    guard ZSTD_isError(remaining) == 0 else { throw Failure.corrupt }
                    guard decoded.count + count <= maximumDecoded else { throw Failure.oversized }
                    decoded.append(contentsOf: output.prefix(count))
                    guard source.pos != previous || count != 0 || remaining == 0 else { throw Failure.corrupt }
                    if remaining == 0 { break }
                }
            }
            cursor += frameSize
            if decoded.isEmpty || decoded.last == 10 {
                committed = cursor; committedBytes = decoded.count
            }
        }
        return Batch(data: Data(decoded.prefix(committedBytes)), consumed: committed)
    }
}
