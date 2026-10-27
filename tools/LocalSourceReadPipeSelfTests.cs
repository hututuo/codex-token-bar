using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace CodexTokenBar.LocalSource;

/// <summary>Offline stream-level contracts for <see cref="LocalSourceReadPipe"/>.</summary>
internal static class LocalSourceReadPipeSelfTests
{
    private static readonly LocalSourceFileIdentity Identity = new(0xFEDCBA9876543210, "0123456789abcdef0123456789ABCDEF");

    public static async Task RunAsync()
    {
        MemoryStreamReturnsRawBinaryPayload();
        await StartsPumpAndCompletesOnParentEofAsync().ConfigureAwait(false);
        await FragmentedHeaderAndPayloadRoundTripAsync().ConfigureAwait(false);
        await EofAndPartialFramesFailPendingReadsAsync().ConfigureAwait(false);
        await OversizeAndWrongIdsFailClosedAsync().ConfigureAwait(false);
        await ParentErrorCodeIsReturnedWithoutDetailsAsync().ConfigureAwait(false);
        await TimeoutAndCancellationAbandonOnlyTheirRequestAsync().ConfigureAwait(false);
        await ConcurrentReadsMatchOutOfOrderResponsesAsync().ConfigureAwait(false);
        RequestBoundsAreCheckedBeforeWriting();
        Console.WriteLine("PASS: local source read pipe contracts");
    }

    private static async Task StartsPumpAndCompletesOnParentEofAsync()
    {
        using var pipes = new AnonymousPipePair();
        var writes = 0;
        using var transport = new LocalSourceReadPipe(pipes.Reader, _ => writes++);
        var completion = transport.Start();
        pipes.CloseWriter();
        await completion.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        await ThrowsCodeAsync(() => transport.Read("C:\\session", Identity, 0, 1, false), "pipe_eof")
            .ConfigureAwait(false);
        if (writes != 0)
        {
            throw new InvalidOperationException("request_written_after_parent_eof");
        }
    }

    private static void MemoryStreamReturnsRawBinaryPayload()
    {
        byte[] payload = [0, (byte)'\n', (byte)'\r', 0xff, 0x80];
        using var responseStream = new MemoryStream(Frame(1, payload));
        string? request = null;
        using var transport = new LocalSourceReadPipe(responseStream, line => request = line);
        var result = transport.Read("C:\\local\\session.jsonl", Identity, ulong.MaxValue, payload.Length, probe: true);
        if (!result.AsSpan().SequenceEqual(payload) || request is null)
        {
            throw new InvalidOperationException("memory_stream_binary_payload");
        }

        using var document = JsonDocument.Parse(request);
        var root = document.RootElement;
        if (root.GetProperty("type").GetString() != "sourceRead"
            || root.GetProperty("id").GetInt64() != 1
            || root.GetProperty("path").GetString() != "C:\\local\\session.jsonl"
            || root.GetProperty("identity").GetProperty("volume").GetUInt64() != Identity.Volume
            || root.GetProperty("identity").GetProperty("fileId").GetString() != Identity.FileId
            || root.GetProperty("offset").GetUInt64() != ulong.MaxValue
            || root.GetProperty("count").GetInt32() != payload.Length
            || !root.GetProperty("probe").GetBoolean())
        {
            throw new InvalidOperationException("request_wire_shape");
        }
    }

    private static async Task FragmentedHeaderAndPayloadRoundTripAsync()
    {
        using var pipes = new AnonymousPipePair();
        var requests = new ConcurrentQueue<string>();
        using var transport = new LocalSourceReadPipe(pipes.Reader, requests.Enqueue, TimeSpan.FromSeconds(2));
        byte[] payload = [0, 0x0a, 0x00, 0x80, 0xff];
        var writer = WriteHeaderAndPayloadInFragmentsAsync(pipes, Frame(1, payload));
        var read = Task.Run(() => transport.Read("D:\\sessions\\split.jsonl", Identity, 17, payload.Length, probe: false));
        var result = await read.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        await writer.ConfigureAwait(false);
        if (!result.AsSpan().SequenceEqual(payload) || requests.IsEmpty)
        {
            throw new InvalidOperationException("fragmented_frame_payload");
        }
    }

    private static async Task EofAndPartialFramesFailPendingReadsAsync()
    {
        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            pipes.CloseWriter();
            await ThrowsCodeAsync(() => transport.Read("C:\\session", Identity, 0, 1, false), "pipe_eof").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            await pipes.WriteAsync(Encoding.UTF8.GetBytes("{\"type\":\"sourceReadResult\""), flush: true).ConfigureAwait(false);
            pipes.CloseWriter();
            await ThrowsCodeAsync(() => transport.Read("C:\\session", Identity, 0, 1, false), "truncated_header").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            var partial = Header(1, 2, null).Concat(new byte[] { 0x7f }).ToArray();
            await pipes.WriteAsync(partial, flush: true).ConfigureAwait(false);
            pipes.CloseWriter();
            await ThrowsCodeAsync(() => transport.Read("C:\\session", Identity, 0, 2, false), "truncated_payload").ConfigureAwait(false);
        }
    }

    private static async Task OversizeAndWrongIdsFailClosedAsync()
    {
        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            await pipes.WriteAsync(Header(1, LocalSourceReadPipe.MaximumTransferBytes + 1, null), flush: true).ConfigureAwait(false);
            await ThrowsCodeAsync(
                () => transport.Read("C:\\session", Identity, 0, 1, false),
                "invalid_response_header").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            var oversizedHeader = Encoding.UTF8.GetBytes(new string('x', LocalSourceReadPipe.MaximumHeaderBytes + 1));
            await pipes.WriteAsync(oversizedHeader, flush: true).ConfigureAwait(false);
            await ThrowsCodeAsync(
                () => transport.Read("C:\\session", Identity, 0, 1, false),
                "header_too_large").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            await pipes.WriteAsync(Frame(2, [0, (byte)'\n', 0]), flush: true).ConfigureAwait(false);
            await ThrowsCodeAsync(
                () => transport.Read("C:\\session", Identity, 0, 3, false),
                "unknown_response_id").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            await pipes.WriteAsync(Frame(1, [0, (byte)'\n']), flush: true).ConfigureAwait(false);
            await ThrowsCodeAsync(
                () => transport.Read("C:\\session", Identity, 0, 1, false),
                "response_exceeds_request").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromMilliseconds(80)))
        {
            try
            {
                _ = transport.Read("C:\\abandoned", Identity, 0, 1, false);
                throw new InvalidOperationException("abandoned_timeout_expected");
            }
            catch (TimeoutException)
            {
            }

            await pipes.WriteAsync(Frame(1, [0x01, 0x02]), flush: true).ConfigureAwait(false);
            await ThrowsCodeAsync(
                () => transport.Read("C:\\after_abandoned", Identity, 0, 1, false),
                "response_exceeds_request").ConfigureAwait(false);
        }

        using (var pipes = new AnonymousPipePair())
        using (var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2)))
        {
            await pipes.WriteAsync(Frame(1, [0x01]).Concat(Frame(1, [0x02])).ToArray(), flush: true).ConfigureAwait(false);
            var first = await Task.Run(() => transport.Read("C:\\first", Identity, 0, 1, false))
                .WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            if (!first.AsSpan().SequenceEqual(new byte[] { 0x01 }))
            {
                throw new InvalidOperationException("first_response_before_duplicate");
            }

            await ThrowsCodeAsync(
                () => transport.Read("C:\\after_duplicate", Identity, 0, 1, false),
                "duplicate_response_id").ConfigureAwait(false);
        }
    }

    private static async Task ParentErrorCodeIsReturnedWithoutDetailsAsync()
    {
        using var pipes = new AnonymousPipePair();
        using var transport = new LocalSourceReadPipe(pipes.Reader, static _ => { }, TimeSpan.FromSeconds(2));
        await pipes.WriteAsync(Frame(1, [], "identity_changed"), flush: true).ConfigureAwait(false);
        await ThrowsCodeAsync(
            () => transport.Read("C:\\session", Identity, 0, 0, false),
            "identity_changed").ConfigureAwait(false);
    }

    private static async Task TimeoutAndCancellationAbandonOnlyTheirRequestAsync()
    {
        using var pipes = new AnonymousPipePair();
        var requests = new ConcurrentQueue<string>();
        using var transport = new LocalSourceReadPipe(pipes.Reader, requests.Enqueue, TimeSpan.FromMilliseconds(90));
        try
        {
            _ = transport.Read("C:\\timeout", Identity, 0, 1, false);
            throw new InvalidOperationException("timeout_expected");
        }
        catch (TimeoutException)
        {
        }

        using (var cancellation = new CancellationTokenSource())
        {
            var canceledRead = Task.Run(() => transport.Read("C:\\cancel", Identity, 0, 3, false, cancellation.Token));
            await WaitForRequestsAsync(requests, 2).ConfigureAwait(false);
            cancellation.Cancel();
            try
            {
                _ = await canceledRead.ConfigureAwait(false);
                throw new InvalidOperationException("cancellation_expected");
            }
            catch (OperationCanceledException)
            {
            }
        }

        var liveRead = Task.Run(() => transport.Read("C:\\live", Identity, 0, 2, false));
        var lines = await WaitForRequestsAsync(requests, 3).ConfigureAwait(false);
        var canceledId = RequestId(lines[1]);
        var liveId = RequestId(lines[2]);
        var late = Frame(canceledId, [0, (byte)'\n', 0]);
        var livePayload = new byte[] { 0xa1, 0x0a };
        var combined = late.Concat(Frame(liveId, livePayload)).ToArray();
        await WriteFragmentedFrameAsync(pipes, combined).ConfigureAwait(false);
        var result = await liveRead.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        if (!result.AsSpan().SequenceEqual(livePayload))
        {
            throw new InvalidOperationException("late_cancelled_payload_desynchronized_pipe");
        }
    }

    private static async Task ConcurrentReadsMatchOutOfOrderResponsesAsync()
    {
        using var pipes = new AnonymousPipePair();
        var requests = new ConcurrentQueue<string>();
        using var transport = new LocalSourceReadPipe(pipes.Reader, requests.Enqueue, TimeSpan.FromSeconds(2), maxPending: 2);
        var first = Task.Run(() => transport.Read("C:\\first", Identity, 1, 1, false));
        var second = Task.Run(() => transport.Read("C:\\second", Identity, 2, 2, true));
        var lines = await WaitForRequestsAsync(requests, 2).ConfigureAwait(false);
        var requestsByPath = lines.ToDictionary(RequestPath, RequestId, StringComparer.Ordinal);
        var firstPayload = new byte[] { 0x41 };
        var secondPayload = new byte[] { 0x42, 0x0a };
        var responseBytes = Frame(requestsByPath["C:\\second"], secondPayload)
            .Concat(Frame(requestsByPath["C:\\first"], firstPayload)).ToArray();
        await pipes.WriteAsync(responseBytes, flush: true).ConfigureAwait(false);
        var results = await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        if (!results[0].AsSpan().SequenceEqual(firstPayload) || !results[1].AsSpan().SequenceEqual(secondPayload))
        {
            throw new InvalidOperationException("concurrent_response_id_correlation");
        }
    }

    private static void RequestBoundsAreCheckedBeforeWriting()
    {
        using var input = new MemoryStream();
        var writes = 0;
        using var transport = new LocalSourceReadPipe(input, _ => writes++);
        try
        {
            _ = transport.Read("C:\\session", Identity, 0, LocalSourceReadPipe.MaximumTransferBytes + 1, false);
            throw new InvalidOperationException("request_size_expected");
        }
        catch (ArgumentOutOfRangeException)
        {
        }

        if (writes != 0)
        {
            throw new InvalidOperationException("invalid_request_was_written");
        }

        try
        {
            _ = transport.Read("C:\\session\nforged", Identity, 0, 0, false);
            throw new InvalidOperationException("control_path_expected");
        }
        catch (ArgumentException error) when (error.Message.Contains("invalid_path", StringComparison.Ordinal))
        {
        }

        using var oversizedPathTransport = new LocalSourceReadPipe(input, _ => writes++);
        try
        {
            _ = oversizedPathTransport.Read(new string('x', LocalSourceReadPipe.MaximumHeaderBytes), Identity, 0, 0, false);
            throw new InvalidOperationException("request_header_size_expected");
        }
        catch (LocalSourceReadException error) when (error.Code == "request_too_large")
        {
        }

        if (writes != 0)
        {
            throw new InvalidOperationException("oversized_request_was_written");
        }
    }

    private static async Task ThrowsCodeAsync(Func<byte[]> action, string expectedCode)
    {
        try
        {
            _ = await Task.Run(action).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);
            throw new InvalidOperationException("expected_transport_error");
        }
        catch (LocalSourceReadException error) when (error.Code == expectedCode)
        {
        }
    }

    private static async Task<string[]> WaitForRequestsAsync(ConcurrentQueue<string> requests, int count)
    {
        var timer = Stopwatch.StartNew();
        while (requests.Count < count)
        {
            if (timer.Elapsed > TimeSpan.FromSeconds(2))
            {
                throw new TimeoutException("request_line_timeout");
            }

            await Task.Delay(5).ConfigureAwait(false);
        }

        return requests.ToArray();
    }

    private static long RequestId(string request)
    {
        using var document = JsonDocument.Parse(request);
        return document.RootElement.GetProperty("id").GetInt64();
    }

    private static string RequestPath(string request)
    {
        using var document = JsonDocument.Parse(request);
        return document.RootElement.GetProperty("path").GetString()!;
    }

    private static byte[] Header(long id, int count, string? error)
    {
        var json = JsonSerializer.Serialize(new { type = "sourceReadResult", id, count, error });
        return Encoding.UTF8.GetBytes(json + "\n");
    }

    private static byte[] Frame(long id, byte[] payload, string? error = null) => Header(id, payload.Length, error)
        .Concat(payload).ToArray();

    private static async Task WriteFragmentedFrameAsync(AnonymousPipePair pipes, byte[] frame)
    {
        var first = Math.Min(3, frame.Length);
        await pipes.WriteAsync(frame.AsMemory(0, first), flush: true).ConfigureAwait(false);
        await Task.Delay(5).ConfigureAwait(false);
        var second = Math.Min(13, frame.Length - first);
        if (second > 0)
        {
            await pipes.WriteAsync(frame.AsMemory(first, second), flush: true).ConfigureAwait(false);
            await Task.Delay(5).ConfigureAwait(false);
        }

        if (first + second < frame.Length)
        {
            await pipes.WriteAsync(frame.AsMemory(first + second), flush: true).ConfigureAwait(false);
        }
    }

    private static async Task WriteHeaderAndPayloadInFragmentsAsync(AnonymousPipePair pipes, byte[] frame)
    {
        var headerEnd = Array.IndexOf(frame, (byte)'\n');
        if (headerEnd < 1)
        {
            throw new InvalidOperationException("test_frame_missing_header_terminator");
        }

        await pipes.WriteAsync(frame.AsMemory(0, 3), flush: true).ConfigureAwait(false);
        await Task.Delay(5).ConfigureAwait(false);
        await pipes.WriteAsync(frame.AsMemory(3, headerEnd + 1 - 3), flush: true).ConfigureAwait(false);
        await Task.Delay(5).ConfigureAwait(false);
        var bodyOffset = headerEnd + 1;
        var firstBodyPart = Math.Min(2, frame.Length - bodyOffset);
        await pipes.WriteAsync(frame.AsMemory(bodyOffset, firstBodyPart), flush: true).ConfigureAwait(false);
        await Task.Delay(5).ConfigureAwait(false);
        if (bodyOffset + firstBodyPart < frame.Length)
        {
            await pipes.WriteAsync(frame.AsMemory(bodyOffset + firstBodyPart), flush: true).ConfigureAwait(false);
        }
    }

    private sealed class AnonymousPipePair : IDisposable
    {
        private readonly AnonymousPipeServerStream _writer = new(PipeDirection.Out, HandleInheritability.None);

        public AnonymousPipePair()
        {
            Reader = new AnonymousPipeClientStream(PipeDirection.In, _writer.ClientSafePipeHandle);
        }

        public AnonymousPipeClientStream Reader { get; }

        public Task WriteAsync(byte[] bytes, bool flush) => WriteAsync(bytes.AsMemory(), flush);

        public async Task WriteAsync(ReadOnlyMemory<byte> bytes, bool flush)
        {
            await _writer.WriteAsync(bytes).ConfigureAwait(false);
            if (flush)
            {
                await _writer.FlushAsync().ConfigureAwait(false);
            }
        }

        public void CloseWriter() => _writer.Dispose();

        public void Dispose()
        {
            Reader.Dispose();
            _writer.Dispose();
        }
    }
}
