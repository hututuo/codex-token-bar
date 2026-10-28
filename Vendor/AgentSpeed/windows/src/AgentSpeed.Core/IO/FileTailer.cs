using System.Buffers;
using AgentSpeed.Core;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.IO;

/// <summary>Reads appended bytes of one plain JSONL transcript and splits them into complete lines (METRICS 5).</summary>
internal class FileTailer : TranscriptTailer
{
    public const int MaxLineBytes = LineSplitter.MaxLineBytes;
    private const int ChunkBytes = 1024 * 1024;

    private StartAlignment _alignment;

    public FileTailer(string path, IPositionedReadBackend? readBackend = null)
        : base(path, readBackend)
    {
    }

    public override void StartAt(long offset, StartAlignment alignment = StartAlignment.None)
    {
        Offset = Math.Max(0, offset);
        _alignment = Offset > 0 ? alignment : StartAlignment.None;
        Lines.Clear();
        Lines.AlignToNextLine = _alignment != StartAlignment.None;
    }

    public override TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default)
    {
        using var handle = Open(Path);
        var length = RandomAccess.GetLength(handle);
        var wasReset = false;
        if (Replaced(handle, length))
        {
            Offset = 0;
            _alignment = StartAlignment.None;
            Lines.Clear();
            wasReset = true;
        }

        if (_alignment == StartAlignment.SkipPartialLine && Offset <= length)
        {
            Span<byte> previous = stackalloc byte[1];
            Lines.AlignToNextLine = ReadAt(handle, previous, Offset - 1, probe: true, cancellationToken) != 1
                || previous[0] != (byte)'\n';
        }

        _alignment = StartAlignment.None;
        long bytesRead = 0;
        SourceReadObservation? observation = null;
        if (length > Offset)
        {
            var buffer = ArrayPool<byte>.Shared.Rent((int)Math.Min(ChunkBytes, length - Offset));
            try
            {
                while (Offset < length)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var want = (int)Math.Min(buffer.Length, length - Offset);
                    var read = ReadAt(handle, buffer.AsSpan(0, want), Offset, cancellationToken: cancellationToken);
                    if (read <= 0)
                    {
                        break;
                    }

                    observation ??= SourceReadObservation.Capture(SourceReadMode.Log, sourceResolutionMs: null);
                    Offset += read;
                    bytesRead += read;
                    Lines.Consume(buffer.AsSpan(0, read), sink);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
        }

        TotalBytesRead += bytesRead;
        Lines.Trim();
        return new TailReadResult(wasReset, length, File.GetLastWriteTimeUtc(handle), bytesRead, observation);
    }
}
