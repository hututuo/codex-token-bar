using System.Buffers;
using AgentSpeed.Core.Parsing;
using Microsoft.Win32.SafeHandles;
using ZstdSharp;

namespace AgentSpeed.Core.IO;

/// <summary>A file that is read again from the start whenever its size, modification time or identity changes.</summary>
internal abstract class WholeFileTailer : TranscriptTailer
{
    private (long Length, DateTime WriteUtc)? _read;

    protected WholeFileTailer(string path)
        : base(path)
    {
    }

    /// <summary>A positive offset means "already read at that size" (files that start at their end).</summary>
    public override void StartAt(long offset, StartAlignment alignment = StartAlignment.None)
    {
        Offset = Math.Max(0, offset);
        Lines.Clear();
        _read = Offset > 0 ? (Offset, default) : null;
    }

    /// <summary>Starts at the end of a file observed with this size and modification time (it is read once either changes).</summary>
    public void StartAtEnd(long length, DateTime lastWriteUtc)
    {
        StartAt(length);
        _read = (Offset, lastWriteUtc);
    }

    public override TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default)
    {
        using var handle = Open(Path);
        var length = RandomAccess.GetLength(handle);
        var writeUtc = File.GetLastWriteTimeUtc(handle);
        var identity = FileIdentity.From(handle);
        var replaced = Identity is { } known && identity is { } current && known != current;
        Identity = identity;
        if (!replaced && _read is { } read && read.Length == length && (read.WriteUtc == default || read.WriteUtc == writeUtc))
        {
            _read = (length, writeUtc);
            return new TailReadResult(false, length, writeUtc, 0);
        }

        var wasRead = _read is not null;
        _read = (length, writeUtc);
        Offset = 0;
        Lines.Clear();
        var bytes = ReadWhole(handle, length, sink, cancellationToken);
        Offset = length;
        TotalBytesRead += bytes;
        return new TailReadResult(wasRead && ResetsParser, length, writeUtc, bytes);
    }

    /// <summary>Whether a re-read must reset the parser first (it replays everything from the start).</summary>
    protected abstract bool ResetsParser { get; }

    protected abstract long ReadWhole(SafeFileHandle handle, long length, ILineSink sink, CancellationToken cancellationToken);
}

/// <summary>
/// A compressed Codex session (<c>.jsonl.zst</c>, METRICS 5.3): one zstd stream decoded with bounded buffers from the
/// start (any number of frames, skippable frames skipped, no per-frame output limit). Never tailed.
/// </summary>
internal sealed class ZstStreamTailer(string path) : WholeFileTailer(path)
{
    private const int ChunkBytes = 1024 * 1024;

    protected override bool ResetsParser => true;

    protected override long ReadWhole(SafeFileHandle handle, long length, ILineSink sink, CancellationToken cancellationToken)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(ChunkBytes);
        try
        {
            using var file = new FileStream(handle, FileAccess.Read, bufferSize: 0);
            using var zstd = new DecompressionStream(file, ChunkBytes, checkEndOfStream: true, leaveOpen: true);
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                int read;
                try
                {
                    read = zstd.Read(buffer, 0, buffer.Length);
                }
                catch (Exception e) when (e is ZstdException or InvalidDataException or IOException)
                {
                    // A decoding error stops the file; what was parsed before stays.
                    sink.OnMalformed();
                    break;
                }

                if (read <= 0)
                {
                    break;
                }

                Lines.Consume(buffer.AsSpan(0, read), sink);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
            Lines.Clear();
        }

        return length;
    }
}

/// <summary>
/// A legacy Gemini CLI session (<c>.json</c>, METRICS 4.6): one JSON document rewritten in place, handed to the parser
/// whole. Documents over <see cref="MaxBytes"/> are not read.
/// </summary>
internal sealed class DocumentTailer(string path) : WholeFileTailer(path)
{
    public const int MaxBytes = Gemini.GeminiParser.MaxDocumentBytes;

    /// <summary>The last read found the document over the size cap.</summary>
    public bool Oversized { get; private set; }

    /// <summary>The parser resets itself once a document parses; a torn read keeps the previous state.</summary>
    protected override bool ResetsParser => false;

    protected override long ReadWhole(SafeFileHandle handle, long length, ILineSink sink, CancellationToken cancellationToken)
    {
        Oversized = length > MaxBytes;
        if (Oversized)
        {
            return 0;
        }

        var size = (int)length;
        var buffer = ArrayPool<byte>.Shared.Rent(Math.Max(1, size));
        try
        {
            var total = 0;
            while (total < size)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var read = RandomAccess.Read(handle, buffer.AsSpan(total, size - total), total);
                if (read <= 0)
                {
                    break;
                }

                total += read;
            }

            sink.OnLine(buffer.AsSpan(0, total));
            return total;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
