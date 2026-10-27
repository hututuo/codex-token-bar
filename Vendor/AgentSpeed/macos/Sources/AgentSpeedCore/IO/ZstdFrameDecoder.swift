import CZstd

/// A zstd decompression context, reused for the frames of one read (METRICS 5.1).
final class ZstdFrameDecoder {
    private let context: OpaquePointer
    private var output: [UInt8] = []

    init?() {
        guard let context = ZSTD_createDCtx() else { return nil }
        self.context = context
    }

    deinit {
        ZSTD_freeDCtx(context)
    }

    /// Streams one complete frame through the decoder and hands its output to `body` once the frame (and its checksum)
    /// is verified. Returns false, handing over nothing, when the frame is corrupt or decodes to more than `limit` bytes.
    func decode(_ frame: UnsafeRawBufferPointer, limit: Int, into body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        guard ZSTD_isError(ZSTD_DCtx_reset(context, ZSTD_reset_session_only)) == 0 else { return false }
        if output.isEmpty {
            output = [UInt8](repeating: 0, count: min(limit + 1, ZSTD_DStreamOutSize()))
        }
        var input = ZSTD_inBuffer(src: frame.baseAddress, size: frame.count, pos: 0)
        var produced = 0
        while true {
            if produced == output.count {
                guard output.count <= limit else { return false }
                output.append(contentsOf: repeatElement(0, count: min(output.count, limit + 1 - output.count)))
            }
            let (status, written) = output.withUnsafeMutableBytes { buffer -> (Int, Int) in
                var target = ZSTD_outBuffer(dst: buffer.baseAddress! + produced, size: buffer.count - produced, pos: 0)
                let status = ZSTD_decompressStream(context, &target, &input)
                return (status, target.pos)
            }
            guard ZSTD_isError(status) == 0 else { return false }
            produced += written
            guard produced <= limit else { return false }
            if status == 0 { break }
            // Input exhausted with room to spare: the frame ends early.
            if input.pos == input.size, produced < output.count { return false }
        }
        output.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) }
        return true
    }
}
