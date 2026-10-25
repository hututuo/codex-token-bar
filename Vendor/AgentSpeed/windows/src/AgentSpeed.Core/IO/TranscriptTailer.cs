using AgentSpeed.Core.Parsing;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.IO;

internal readonly record struct TailReadResult(bool WasReset, long Length, DateTime LastWriteUtc, long BytesRead);

/// <summary>How a tailer that starts inside a file treats the bytes before the first newline (METRICS 5).</summary>
internal enum StartAlignment
{
    None,

    /// <summary>Skip the fragment only when the byte before the start offset is not a newline.</summary>
    SkipPartialLine,

    /// <summary>Always skip to the next newline (the large-file tail rule).</summary>
    SkipToNextLine,
}

/// <summary>
/// Reads what was appended to one transcript since the last read and hands complete lines to a sink. Files are
/// opened only for the duration of a read with full sharing so agents are never blocked. Not thread-safe.
/// </summary>
internal abstract class TranscriptTailer
{
    protected TranscriptTailer(string path)
    {
        Path = path;
    }

    public string Path { get; }

    /// <summary>Bytes of the file consumed so far.</summary>
    public long Offset { get; protected set; }

    public FileIdentity? Identity { get; protected set; }

    public long OversizedLines => Lines.OversizedLines;

    public long TotalBytesRead { get; protected set; }

    protected LineSplitter Lines { get; } = new();

    /// <summary>
    /// Plain JSONL for most files, a zstd frame stream for <c>.zstd</c> (METRICS 5.1), a whole zstd stream for Codex
    /// <c>.jsonl.zst</c> (5.3) and a whole document for legacy Gemini <c>.json</c> (4.6).
    /// </summary>
    public static TranscriptTailer For(string path) =>
        path.EndsWith(".zstd", StringComparison.OrdinalIgnoreCase) ? new ZstdFrameTailer(path)
        : path.EndsWith(".jsonl.zst", StringComparison.OrdinalIgnoreCase) ? new ZstStreamTailer(path)
        : path.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? new DocumentTailer(path)
        : new FileTailer(path);

    /// <summary>Opens for reading without ever locking the writer out (read/write/delete sharing).</summary>
    public static SafeFileHandle Open(string path) => File.OpenHandle(
        path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, FileOptions.SequentialScan);

    /// <summary>Positions the tailer before the first read.</summary>
    public abstract void StartAt(long offset, StartAlignment alignment = StartAlignment.None);

    public abstract TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default);

    /// <summary>Records identity and size without reading (files that start at their current size).</summary>
    public TailReadResult Prime(long offset)
    {
        using var handle = Open(Path);
        var length = RandomAccess.GetLength(handle);
        Identity = FileIdentity.From(handle);
        StartAt(Math.Min(offset, length));
        return new TailReadResult(false, length, File.GetLastWriteTimeUtc(handle), 0);
    }

    /// <summary>Records the current identity; true when the file shrank or was replaced since the last read.</summary>
    protected bool Replaced(SafeFileHandle handle, long length)
    {
        var identity = FileIdentity.From(handle);
        var replaced = length < Offset || (Identity is { } known && identity is { } current && known != current);
        Identity = identity;
        return replaced;
    }
}
