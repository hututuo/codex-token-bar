using System.Buffers;
using System.Buffers.Binary;
using System.Diagnostics.CodeAnalysis;
using AgentSpeed.Core.Parsing;
using Microsoft.Win32.SafeHandles;
using ZstdSharp.Unsafe;

namespace AgentSpeed.Core.IO;

/// <summary>
/// Reads a transcript stored as a sequence of independent zstd frames (METRICS 5.1): every complete frame is
/// decoded on its own and its bytes are split into lines; an incomplete trailing frame waits for more bytes.
/// </summary>
internal sealed class ZstdFrameTailer : TranscriptTailer
{
    public const int MaxFrameOutputBytes = 64 * 1024 * 1024;

    /// <summary>Largest compressed frame that is buffered whole; beyond it the stream is resynchronized.</summary>
    public const int MaxFrameInputBytes = 256 * 1024 * 1024;

    private const uint FrameMagic = 0xFD2FB528;
    private const uint SkippableMagic = 0x184D2A50;
    private const uint SkippableMask = 0xFFFFFFF0;
    private const int MinWindowBytes = 64 * 1024;
    private const int InitialWindowBytes = 1024 * 1024;

    /// <summary>Larger buffers are left to the GC so a rare huge frame is not retained by the shared pool.</summary>
    private const int PooledBytes = 1024 * 1024;

    private bool _resyncing;

    public ZstdFrameTailer(string path)
        : base(path)
    {
    }

    /// <summary>Frames that failed to decode, exceeded the output cap or could not be framed.</summary>
    public long MalformedFrames { get; private set; }

    /// <summary>Frames start at frame boundaries, so <paramref name="alignment"/> does not apply.</summary>
    public override void StartAt(long offset, StartAlignment alignment = StartAlignment.None)
    {
        Offset = Math.Max(0, offset);
        _resyncing = false;
        Lines.Clear();
    }

    public override TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default)
    {
        using var handle = Open(Path);
        var length = RandomAccess.GetLength(handle);
        var wasReset = false;
        if (Replaced(handle, length))
        {
            StartAt(0);
            wasReset = true;
        }

        long consumed = 0;
        if (length > Offset)
        {
            using var decoder = new FrameDecoder();
            var window = Rent((int)Math.Clamp(length - Offset, MinWindowBytes, InitialWindowBytes));
            try
            {
                while (Offset < length)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var available = length - Offset;
                    var fill = Fill(handle, window, (int)Math.Min(window.Length, available), Offset);
                    var atEnd = fill >= available || fill < Math.Min(window.Length, available);
                    var used = Scan(window.AsSpan(0, fill), decoder, sink);
                    Offset += used;
                    consumed += used;
                    if ((atEnd && used < fill) || fill == 0)
                    {
                        break;
                    }

                    if (used == 0)
                    {
                        if (window.Length >= MaxFrameInputBytes)
                        {
                            Desync(sink);
                            Offset++;
                            consumed++;
                            continue;
                        }

                        var grown = Rent((int)Math.Min(Math.Min((long)window.Length * 2, MaxFrameInputBytes), available));
                        Return(window);
                        window = grown;
                    }
                }
            }
            finally
            {
                Return(window);
            }
        }

        TotalBytesRead += consumed;
        Lines.Trim();
        return new TailReadResult(wasReset, length, File.GetLastWriteTimeUtc(handle), consumed);
    }

    private static byte[] Rent(int size) =>
        size <= PooledBytes ? ArrayPool<byte>.Shared.Rent(size) : GC.AllocateUninitializedArray<byte>(size);

    private static void Return(byte[] buffer)
    {
        if (buffer.Length <= PooledBytes)
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static int Fill(SafeFileHandle handle, byte[] buffer, int want, long offset)
    {
        var total = 0;
        while (total < want)
        {
            var read = RandomAccess.Read(handle, buffer.AsSpan(total, want - total), offset + total);
            if (read <= 0)
            {
                break;
            }

            total += read;
        }

        return total;
    }

    /// <summary>Consumes every complete frame in <paramref name="data"/>; returns how many bytes were used.</summary>
    /// <remarks>An incomplete frame stops the scan; the caller decides whether to wait or read a larger window.</remarks>
    private int Scan(ReadOnlySpan<byte> data, FrameDecoder decoder, ILineSink sink)
    {
        var position = 0;
        while (position < data.Length)
        {
            var rest = data[position..];
            if (_resyncing)
            {
                var next = IndexOfMagic(rest);
                if (next < 0)
                {
                    // Keep a possible magic number split across reads.
                    return Math.Max(position, data.Length - 3);
                }

                _resyncing = false;
                position += next;
                continue;
            }

            switch (FrameDecoder.FrameSize(rest, out var size))
            {
                case FrameStatus.Incomplete:
                    return position;
                case FrameStatus.Invalid:
                    Desync(sink);
                    position++;
                    continue;
            }

            var frame = rest[..size];
            position += size;
            if ((BinaryPrimitives.ReadUInt32LittleEndian(frame) & SkippableMask) == SkippableMagic)
            {
                continue;
            }

            if (decoder.TryDecode(frame, out var decoded))
            {
                Lines.Consume(decoded, sink);
            }
            else
            {
                MalformedFrames++;
                sink.OnMalformed();
            }
        }

        return position;
    }

    private void Desync(ILineSink sink)
    {
        _resyncing = true;
        MalformedFrames++;
        sink.OnMalformed();
    }

    private static int IndexOfMagic(ReadOnlySpan<byte> data)
    {
        for (var i = 0; i + 4 <= data.Length; i++)
        {
            var value = BinaryPrimitives.ReadUInt32LittleEndian(data[i..]);
            if (value == FrameMagic || (value & SkippableMask) == SkippableMagic)
            {
                return i;
            }
        }

        return -1;
    }

    private enum FrameStatus
    {
        Complete,
        Incomplete,
        Invalid,
    }

    /// <summary>One zstd decompression context for the duration of a read, reset before every frame.</summary>
    private sealed unsafe class FrameDecoder : IDisposable
    {
        private const int ChunkBytes = 128 * 1024;

        private ZSTD_DCtx_s* _context;
        private byte[]? _chunk;
        private byte[]? _output;

        public static FrameStatus FrameSize(ReadOnlySpan<byte> data, out int size)
        {
            nuint result;
            fixed (byte* source = data)
            {
                result = Methods.ZSTD_findFrameCompressedSize(source, (nuint)data.Length);
            }

            if (Methods.ZSTD_isError(result))
            {
                size = 0;
                return Methods.ZSTD_getErrorCode(result) == ZSTD_ErrorCode.ZSTD_error_srcSize_wrong
                    ? FrameStatus.Incomplete
                    : FrameStatus.Invalid;
            }

            if (result == 0 || result > (nuint)data.Length)
            {
                size = 0;
                return FrameStatus.Invalid;
            }

            size = (int)result;
            return FrameStatus.Complete;
        }

        /// <summary>Decodes exactly one frame; false when it is corrupt, truncated or over the output cap.</summary>
        public bool TryDecode(ReadOnlySpan<byte> frame, out ReadOnlySpan<byte> decoded)
        {
            decoded = default;
            if (_context == null)
            {
                _context = Methods.ZSTD_createDCtx();
                if (_context == null)
                {
                    throw new InsufficientMemoryException("zstd decompression context");
                }
            }
            else
            {
                Methods.ZSTD_DCtx_reset(_context, ZSTD_ResetDirective.ZSTD_reset_session_only);
            }

            _chunk ??= Rent(ChunkBytes);
            var written = 0;
            fixed (byte* source = frame)
            fixed (byte* chunk = _chunk)
            {
                var input = new ZSTD_inBuffer_s { src = source, size = (nuint)frame.Length, pos = 0 };
                while (true)
                {
                    var output = new ZSTD_outBuffer_s { dst = chunk, size = (nuint)_chunk.Length, pos = 0 };
                    var hint = Methods.ZSTD_decompressStream(_context, &output, &input);
                    if (Methods.ZSTD_isError(hint))
                    {
                        return false;
                    }

                    var produced = (int)output.pos;
                    if (produced > MaxFrameOutputBytes - written)
                    {
                        return false;
                    }

                    if (produced > 0)
                    {
                        EnsureOutput(written + produced, written);
                        _chunk.AsSpan(0, produced).CopyTo(_output.AsSpan(written));
                        written += produced;
                    }

                    if (hint == 0)
                    {
                        decoded = _output.AsSpan(0, written);
                        return true;
                    }

                    if (input.pos == input.size && output.pos < output.size)
                    {
                        return false;
                    }
                }
            }
        }

        public void Dispose()
        {
            if (_context != null)
            {
                Methods.ZSTD_freeDCtx(_context);
                _context = null;
            }

            if (_chunk is not null)
            {
                Return(_chunk);
                _chunk = null;
            }

            if (_output is not null)
            {
                Return(_output);
                _output = null;
            }
        }

        [MemberNotNull(nameof(_output))]
        private void EnsureOutput(int needed, int keep)
        {
            if (_output is not null && _output.Length >= needed)
            {
                return;
            }

            var grown = Rent(Math.Min(MaxFrameOutputBytes, Math.Max(needed, (_output?.Length ?? ChunkBytes / 2) * 2)));
            if (_output is not null)
            {
                _output.AsSpan(0, keep).CopyTo(grown);
                Return(_output);
            }

            _output = grown;
        }
    }
}
