using System.Buffers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using AgentSpeed.Core.IO;

namespace CodexTokenBar.LocalSource;

internal readonly record struct LocalSourceFileIdentity(
    [property: JsonPropertyName("volume")] ulong Volume,
    [property: JsonPropertyName("fileId")] string FileId);

internal sealed class LocalSourceReadException(string code) : IOException(code)
{
    public string Code { get; } = code;
}

/// <summary>Serializes complete JSON lines from the source-read transport and snapshot/status publishers.</summary>
internal sealed class LocalSourceProtocolOutput(Stream output)
{
    private readonly object _gate = new();
    private readonly Stream _output = output;

    public void WriteLine(string line) => WriteLine(Encoding.UTF8.GetBytes(line));

    public void WriteLine(ReadOnlySpan<byte> line)
    {
        lock (_gate)
        {
            _output.Write(line);
            _output.WriteByte((byte)'\n');
            _output.Flush();
        }
    }
}

/// <summary>
/// Multiplexes bounded local source-read requests over a pair of parent-owned anonymous pipes.
/// This class never opens a process, socket, or filesystem path; the caller supplies the response
/// stream and a callback that writes one request line to the paired output pipe.
/// </summary>
internal sealed class LocalSourceReadPipe : IDisposable, IPositionedReadBackend
{
    public const int MaximumTransferBytes = 4 * 1024 * 1024;
    public const int MaximumHeaderBytes = 4096;
    public const int DefaultMaxPending = 16;

    private static readonly JsonSerializerOptions RequestJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        MaxDepth = 4,
    };

    private readonly object _stateGate = new();
    private readonly object _writeGate = new();
    private readonly Dictionary<long, PendingRead> _pending = [];
    private readonly BufferedPipeInput _input;
    private readonly Action<string> _writeRequestLine;
    private readonly TimeSpan _requestTimeout;
    private readonly int _maxPending;
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _pumpTask;
    private LocalSourceReadException? _terminalFailure;
    private long _lastIssuedId;
    private bool _disposed;

    public LocalSourceReadPipe(
        Stream responseStream,
        Action<string> writeRequestLine,
        TimeSpan? requestTimeout = null,
        int maxPending = DefaultMaxPending)
    {
        ArgumentNullException.ThrowIfNull(responseStream);
        ArgumentNullException.ThrowIfNull(writeRequestLine);
        if (!responseStream.CanRead)
        {
            throw new ArgumentException("response_stream_not_readable", nameof(responseStream));
        }

        if (maxPending is < 1 or > DefaultMaxPending)
        {
            throw new ArgumentOutOfRangeException(nameof(maxPending));
        }

        var timeout = requestTimeout ?? TimeSpan.FromSeconds(5);
        if (timeout <= TimeSpan.Zero && timeout != Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        }

        _input = new BufferedPipeInput(responseStream);
        _writeRequestLine = writeRequestLine;
        _requestTimeout = timeout;
        _maxPending = maxPending;
    }

    /// <summary>
    /// Sends one source read and synchronously waits for the response. A caller timeout or
    /// cancellation abandons only that caller; the request remains as a bounded tombstone until
    /// its response is consumed, so a late payload is checked against the original request size.
    /// </summary>
    public byte[] Read(
        string path,
        LocalSourceFileIdentity expectedFileIdentity,
        ulong offset,
        int count,
        bool probe,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (path.Length == 0 || path.Any(char.IsControl))
        {
            throw new ArgumentException("invalid_path", nameof(path));
        }

        if (path.Length > MaximumHeaderBytes)
        {
            throw new LocalSourceReadException("request_too_large");
        }

        if (count is < 0 or > MaximumTransferBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(count));
        }

        if (!IsFileId(expectedFileIdentity.FileId))
        {
            throw new ArgumentException("invalid_file_identity", nameof(expectedFileIdentity));
        }

        cancellationToken.ThrowIfCancellationRequested();

        TaskCompletionSource<byte[]> completion;
        long requestId;
        lock (_writeGate)
        {
            lock (_stateGate)
            {
                ThrowIfUnavailable();
                if (_pending.Count >= _maxPending)
                {
                    throw new LocalSourceReadException("pending_limit");
                }

                if (_lastIssuedId == long.MaxValue)
                {
                    throw new LocalSourceReadException("request_id_exhausted");
                }

                requestId = ++_lastIssuedId;
                completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
                _pending.Add(requestId, new PendingRead(count, completion));
            }

            string line;
            try
            {
                line = JsonSerializer.Serialize(
                    new SourceReadRequest(requestId, path, expectedFileIdentity, offset, count, probe),
                    RequestJsonOptions);
                if (Encoding.UTF8.GetByteCount(line) > MaximumHeaderBytes)
                {
                    RemovePending(requestId, completion);
                    throw new LocalSourceReadException("request_too_large");
                }

                _writeRequestLine(line);
                EnsurePumpStarted();
            }
            catch (LocalSourceReadException)
            {
                throw;
            }
            catch (Exception)
            {
                var failure = new LocalSourceReadException("pipe_write_failed");
                FailAll(failure);
                throw failure;
            }
        }

        try
        {
            return completion.Task
                .WaitAsync(_requestTimeout, cancellationToken)
                .GetAwaiter()
                .GetResult();
        }
        catch (TimeoutException)
        {
            AbandonPending(requestId, completion);
            throw;
        }
        catch (OperationCanceledException)
        {
            AbandonPending(requestId, completion);
            throw;
        }
    }

    byte[] IPositionedReadBackend.Read(
        string path,
        ulong volume,
        string fileId,
        ulong offset,
        int count,
        bool probe,
        CancellationToken cancellationToken) =>
        Read(path, new LocalSourceFileIdentity(volume, fileId), offset, count, probe, cancellationToken);

    /// <summary>Starts the sole stdin reader even before the first source request, so parent EOF also stops the helper.</summary>
    public Task Start()
    {
        lock (_writeGate)
        {
            EnsurePumpStarted();
            lock (_stateGate)
            {
                return _pumpTask!;
            }
        }
    }

    public void Dispose()
    {
        lock (_writeGate)
        {
            lock (_stateGate)
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;
            }

            FailAll(new LocalSourceReadException("disposed"));
            _lifetime.Cancel();
        }
    }

    private void EnsurePumpStarted()
    {
        lock (_stateGate)
        {
            ThrowIfUnavailable();
            _pumpTask ??= Task.Run(PumpAsync);
        }
    }

    private async Task PumpAsync()
    {
        try
        {
            while (!_lifetime.IsCancellationRequested)
            {
                var header = await _input.ReadBoundedHeaderAsync(MaximumHeaderBytes, _lifetime.Token)
                    .ConfigureAwait(false);
                if (header is null)
                {
                    throw new LocalSourceReadException("pipe_eof");
                }

                var response = ParseResponse(header);
                PendingRead? pending;
                long lastIssuedId;
                lock (_stateGate)
                {
                    _pending.TryGetValue(response.Id, out pending);
                    lastIssuedId = _lastIssuedId;
                }

                var isWithinRequestLimit = pending is not null && response.Count <= pending.Count;
                var payload = isWithinRequestLimit ? new byte[response.Count] : Array.Empty<byte>();
                if (isWithinRequestLimit)
                {
                    await _input.ReadExactlyAsync(payload, _lifetime.Token).ConfigureAwait(false);
                }
                else
                {
                    await _input.DiscardExactlyAsync(response.Count, _lifetime.Token).ConfigureAwait(false);
                }

                if (response.Id > lastIssuedId)
                {
                    throw new LocalSourceReadException("unknown_response_id");
                }

                if (pending is null)
                {
                    // The full payload was consumed above, preserving framing. A response for
                    // an abandoned request remains in _pending until consumed; therefore an
                    // absent id here is a duplicate or an id that was never sent.
                    throw new LocalSourceReadException("duplicate_response_id");
                }

                if (response.Count > pending.Count)
                {
                    throw new LocalSourceReadException("response_exceeds_request");
                }

                bool wasAbandoned;
                lock (_stateGate)
                {
                    if (!_pending.TryGetValue(response.Id, out var active) || !ReferenceEquals(active, pending))
                    {
                        continue;
                    }

                    _pending.Remove(response.Id);
                    wasAbandoned = pending.Abandoned;
                }

                if (wasAbandoned)
                {
                    continue;
                }

                if (response.Error is { } error)
                {
                    pending.Completion.TrySetException(new LocalSourceReadException(error));
                }
                else
                {
                    pending.Completion.TrySetResult(payload);
                }
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (LocalSourceReadException error)
        {
            FailAll(error);
        }
        catch (Exception)
        {
            FailAll(new LocalSourceReadException("pipe_read_failed"));
        }
    }

    private static SourceReadResponse ParseResponse(byte[] header)
    {
        try
        {
            using var document = JsonDocument.Parse(header, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new LocalSourceReadException("invalid_response_header");
            }

            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name is not ("type" or "id" or "count" or "error") || !names.Add(property.Name))
                {
                    throw new LocalSourceReadException("invalid_response_header");
                }
            }

            if (!root.TryGetProperty("type", out var type)
                || type.ValueKind != JsonValueKind.String || type.GetString() != "sourceReadResult"
                || !root.TryGetProperty("id", out var idElement)
                || !idElement.TryGetInt64(out var id) || id <= 0
                || !root.TryGetProperty("count", out var countElement)
                || !countElement.TryGetUInt32(out var rawCount) || rawCount > MaximumTransferBytes
                || !root.TryGetProperty("error", out var errorElement))
            {
                throw new LocalSourceReadException("invalid_response_header");
            }

            string? error = errorElement.ValueKind switch
            {
                JsonValueKind.Null => null,
                JsonValueKind.String when errorElement.GetString() is { } code && IsBoundedErrorCode(code) => code,
                _ => throw new LocalSourceReadException("invalid_response_header"),
            };
            return new SourceReadResponse(id, (int)rawCount, error);
        }
        catch (JsonException)
        {
            throw new LocalSourceReadException("invalid_response_header");
        }
    }

    private static bool IsBoundedErrorCode(string code) =>
        code.Length is > 0 and <= 64
        && code.All(character => character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '_' or '-');

    private static bool IsFileId(string fileId) =>
        fileId is { Length: 32 }
        && fileId.All(Uri.IsHexDigit);

    private void RemovePending(long id, TaskCompletionSource<byte[]> completion)
    {
        lock (_stateGate)
        {
            if (_pending.TryGetValue(id, out var pending) && ReferenceEquals(pending.Completion, completion))
            {
                _pending.Remove(id);
            }
        }
    }

    private void AbandonPending(long id, TaskCompletionSource<byte[]> completion)
    {
        lock (_stateGate)
        {
            if (_pending.TryGetValue(id, out var pending) && ReferenceEquals(pending.Completion, completion))
            {
                pending.Abandoned = true;
                pending.Completion.TrySetCanceled();
            }
        }
    }

    private void ThrowIfUnavailable()
    {
        if (_disposed)
        {
            throw new LocalSourceReadException("disposed");
        }

        if (_terminalFailure is { } failure)
        {
            throw new LocalSourceReadException(failure.Code);
        }
    }

    private void FailAll(LocalSourceReadException failure)
    {
        PendingRead[] pending;
        lock (_stateGate)
        {
            if (_terminalFailure is not null)
            {
                return;
            }

            _terminalFailure = failure;
            pending = _pending.Values.ToArray();
            _pending.Clear();
        }

        foreach (var request in pending)
        {
            request.Completion.TrySetException(new LocalSourceReadException(failure.Code));
        }
    }

    private sealed class PendingRead(int count, TaskCompletionSource<byte[]> completion)
    {
        public int Count { get; } = count;
        public TaskCompletionSource<byte[]> Completion { get; } = completion;
        public bool Abandoned { get; set; }
    }

    private sealed record SourceReadRequest(
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("id")] long Id,
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("identity")] LocalSourceFileIdentity Identity,
        [property: JsonPropertyName("offset")] ulong Offset,
        [property: JsonPropertyName("count")] int Count,
        [property: JsonPropertyName("probe")] bool Probe)
    {
        public SourceReadRequest(long id, string path, LocalSourceFileIdentity identity, ulong offset, int count, bool probe)
            : this("sourceRead", id, path, identity, offset, count, probe)
        {
        }
    }

    private sealed record SourceReadResponse(long Id, int Count, string? Error);

    private sealed class BufferedPipeInput(Stream stream)
    {
        private readonly Stream _stream = stream;
        private readonly byte[] _buffer = new byte[8192];
        private int _offset;
        private int _available;

        public async Task<byte[]?> ReadBoundedHeaderAsync(int maximumBytes, CancellationToken cancellationToken)
        {
            var header = new byte[maximumBytes + 1];
            var count = 0;
            while (true)
            {
                if (_offset == _available)
                {
                    _offset = 0;
                    _available = await _stream.ReadAsync(_buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                    if (_available == 0)
                    {
                        if (count == 0)
                        {
                            return null;
                        }

                        throw new LocalSourceReadException("truncated_header");
                    }
                }

                var lineEnd = Array.IndexOf(_buffer, (byte)'\n', _offset, _available - _offset);
                var copyCount = lineEnd >= 0 ? lineEnd - _offset : _available - _offset;
                if (count + copyCount > maximumBytes + 1)
                {
                    throw new LocalSourceReadException("header_too_large");
                }

                Buffer.BlockCopy(_buffer, _offset, header, count, copyCount);
                count += copyCount;
                _offset += copyCount;
                if (lineEnd >= 0)
                {
                    _offset++; // Consume the newline, retaining any already-buffered payload.
                    if (count > 0 && header[count - 1] == (byte)'\r')
                    {
                        count--;
                    }

                    if (count > maximumBytes)
                    {
                        throw new LocalSourceReadException("header_too_large");
                    }

                    return header.AsSpan(0, count).ToArray();
                }

                if (count > maximumBytes + 1
                    || (count == maximumBytes + 1 && header[count - 1] != (byte)'\r'))
                {
                    throw new LocalSourceReadException("header_too_large");
                }
            }
        }

        public async Task ReadExactlyAsync(Memory<byte> destination, CancellationToken cancellationToken)
        {
            var copied = 0;
            while (copied < destination.Length)
            {
                if (_offset < _available)
                {
                    var count = Math.Min(_available - _offset, destination.Length - copied);
                    _buffer.AsMemory(_offset, count).CopyTo(destination[copied..]);
                    _offset += count;
                    copied += count;
                    continue;
                }

                var read = await _stream.ReadAsync(destination[copied..], cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    throw new LocalSourceReadException("truncated_payload");
                }

                copied += read;
            }
        }

        public async Task DiscardExactlyAsync(int count, CancellationToken cancellationToken)
        {
            if (count == 0)
            {
                return;
            }

            var discardBuffer = ArrayPool<byte>.Shared.Rent(Math.Min(count, 8192));
            try
            {
                var remaining = count;
                while (remaining > 0)
                {
                    var chunk = Math.Min(remaining, discardBuffer.Length);
                    await ReadExactlyAsync(discardBuffer.AsMemory(0, chunk), cancellationToken).ConfigureAwait(false);
                    remaining -= chunk;
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(discardBuffer);
            }
        }
    }
}
