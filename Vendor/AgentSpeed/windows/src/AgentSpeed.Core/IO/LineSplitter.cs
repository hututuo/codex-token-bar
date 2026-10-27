using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.IO;

/// <summary>
/// Splits a byte stream into complete lines, buffering an incomplete trailing line and skipping lines over
/// <see cref="MaxLineBytes"/> (METRICS 4 and 5). Not thread-safe.
/// </summary>
internal sealed class LineSplitter
{
    public const int MaxLineBytes = 32 * 1024 * 1024;

    private byte[]? _partial;
    private int _partialLength;
    private bool _skippingOversized;

    public long OversizedLines { get; private set; }

    /// <summary>When set, bytes up to and including the next newline are dropped.</summary>
    public bool AlignToNextLine { get; set; }

    public void Consume(ReadOnlySpan<byte> data, ILineSink sink)
    {
        if (AlignToNextLine)
        {
            var first = data.IndexOf((byte)'\n');
            if (first < 0)
            {
                return;
            }

            AlignToNextLine = false;
            data = data[(first + 1)..];
        }

        while (!data.IsEmpty)
        {
            var newline = data.IndexOf((byte)'\n');
            if (newline < 0)
            {
                AppendPartial(data);
                return;
            }

            var segment = data[..newline];
            data = data[(newline + 1)..];
            if (_skippingOversized)
            {
                _skippingOversized = false;
                OversizedLines++;
                continue;
            }

            if (_partialLength == 0)
            {
                Emit(segment, sink);
                continue;
            }

            if ((long)_partialLength + segment.Length > MaxLineBytes)
            {
                OversizedLines++;
            }
            else
            {
                AppendPartial(segment);
                Emit(_partial.AsSpan(0, _partialLength), sink);
            }

            _partialLength = 0;
        }
    }

    /// <summary>Drops the buffered incomplete line and any pending alignment.</summary>
    public void Clear()
    {
        _partial = null;
        _partialLength = 0;
        _skippingOversized = false;
        AlignToNextLine = false;
    }

    /// <summary>Returns the partial-line buffer to the GC when nothing is buffered.</summary>
    public void Trim()
    {
        if (_partialLength == 0)
        {
            _partial = null;
        }
    }

    private void Emit(ReadOnlySpan<byte> line, ILineSink sink)
    {
        if (line.Length > MaxLineBytes)
        {
            OversizedLines++;
            return;
        }

        if (!line.IsEmpty && line[^1] == '\r')
        {
            line = line[..^1];
        }

        sink.OnLine(line);
    }

    private void AppendPartial(ReadOnlySpan<byte> data)
    {
        if (_skippingOversized)
        {
            return;
        }

        var needed = (long)_partialLength + data.Length;
        if (needed > MaxLineBytes)
        {
            _skippingOversized = true;
            _partialLength = 0;
            return;
        }

        if (_partial is null || _partial.Length < needed)
        {
            var grown = new byte[(int)Math.Min(MaxLineBytes, Math.Max(needed, Math.Max(64 * 1024, (_partial?.Length ?? 0) * 2L)))];
            _partial.AsSpan(0, _partialLength).CopyTo(grown);
            _partial = grown;
        }

        data.CopyTo(_partial.AsSpan(_partialLength));
        _partialLength = (int)needed;
    }
}
