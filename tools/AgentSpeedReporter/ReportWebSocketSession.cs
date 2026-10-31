using System.Buffers;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

internal sealed record WebSocketReady(ReportWebSocketSettings Settings, DateTimeOffset ServerTime);

internal sealed record WebSocketAck(
    string RunId,
    int Seq,
    string Status,
    string BodySha256,
    DateTimeOffset ReceivedAt,
    DateTimeOffset AcceptedAt);

internal sealed record WebSocketError(
    string? RunId,
    int? Seq,
    int HttpStatus,
    string Code,
    int? RetryAfterSeconds,
    long? ServerTime,
    bool Fatal);

internal sealed class WebSocketHandshakeException(HttpStatusCode statusCode, int? retryAfterSeconds)
    : Exception($"WebSocket handshake failed with HTTP {(int)statusCode}.")
{
    public HttpStatusCode StatusCode { get; } = statusCode;
    public int? RetryAfterSeconds { get; } = retryAfterSeconds;
}

internal sealed class CaptureHandshakeHandler(HttpMessageHandler innerHandler) : DelegatingHandler(innerHandler)
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.SwitchingProtocols)
        {
            var statusCode = response.StatusCode;
            var retryAfter = response.Headers.RetryAfter?.Delta is { } delta
                ? (int?)Math.Clamp((int)Math.Ceiling(delta.TotalSeconds), 1, 86_400)
                : response.Headers.RetryAfter?.Date is { } date
                    ? (int?)Math.Clamp((int)Math.Ceiling((date - DateTimeOffset.UtcNow).TotalSeconds), 1, 86_400)
                    : null;
            response.Dispose();
            throw new WebSocketHandshakeException(statusCode, retryAfter);
        }

        return response;
    }
}

internal abstract record WebSocketMessage
{
    private WebSocketMessage() { }

    public sealed record Ack(WebSocketAck Value) : WebSocketMessage;
    public sealed record Error(WebSocketError Value) : WebSocketMessage;
}

internal sealed class ReportWebSocketCloseException(WebSocketCloseStatus? closeStatus, string? description)
    : Exception($"WebSocket closed ({(int?)closeStatus}: {description}).")
{
    public WebSocketCloseStatus? CloseStatus { get; } = closeStatus;
}

internal sealed class ReportWebSocketSession : IAsyncDisposable
{
    private const int ReceiveChunkBytes = 8_192;
    private const int ReadyTimeoutSeconds = 10;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private readonly ClientWebSocket _socket;
    private readonly HttpMessageInvoker _invoker;
    private readonly Channel<byte[]> _incoming;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Task _reader;
    private int _disposed;

    private ReportWebSocketSession(ClientWebSocket socket, HttpMessageInvoker invoker, int maxMessageBytes)
    {
        _socket = socket;
        _invoker = invoker;
        MaxMessageBytes = maxMessageBytes;
        _incoming = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(64)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = true,
            AllowSynchronousContinuations = false,
        });
        _reader = ReceiveLoopAsync(_lifetime.Token);
    }

    public int MaxMessageBytes { get; }

    public static async Task<(ReportWebSocketSession Session, WebSocketReady Ready)> ConnectAsync(
        ReportDiscovery discovery,
        string userAgent,
        string deviceId,
        IReportSigner signer,
        long timestamp,
        CancellationToken cancellationToken)
    {
        var settings = discovery.WebSocket ?? throw new ReporterFailure("websocket_not_supported");
        var uri = discovery.Api.WebSocketEndpoint();
        var request = new ReportRequestBuilder(userAgent, deviceId, ApiKey: null)
            .Make("GET", uri, Array.Empty<byte>(), signer, timestamp);
        var socket = new ClientWebSocket();
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(settings.PingIntervalSeconds);
        socket.Options.KeepAliveTimeout = TimeSpan.FromSeconds(settings.PongTimeoutSeconds);
        socket.Options.HttpVersion = HttpVersion.Version11;
        socket.Options.HttpVersionPolicy = HttpVersionPolicy.RequestVersionExact;
        socket.Options.AddSubProtocol(ReportWebSocketSettings.Subprotocol);
        foreach (var header in request.Headers)
        {
            if (header.Key is ReportCanonical.DeviceHeader or ReportCanonical.TimestampHeader
                or ReportCanonical.NonceHeader or ReportCanonical.SignatureHeader or "Authorization" or "User-Agent")
            {
                socket.Options.SetRequestHeader(header.Key, header.Value);
            }
        }

        var socketsHandler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            Credentials = null,
            DefaultProxyCredentials = null,
            PreAuthenticate = false,
            UseProxy = true,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            MaxConnectionsPerServer = 1,
            MaxResponseHeadersLength = 64,
            SslOptions = new System.Net.Security.SslClientAuthenticationOptions
            {
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                ClientCertificates = null,
                LocalCertificateSelectionCallback = null,
            },
        };
        var handler = new CaptureHandshakeHandler(socketsHandler);
        var invoker = new HttpMessageInvoker(handler, disposeHandler: true);
        ReportWebSocketSession? session = null;
        try
        {
            using (var connectDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                connectDeadline.CancelAfter(TimeSpan.FromSeconds(ReadyTimeoutSeconds));
                await socket.ConnectAsync(uri, invoker, connectDeadline.Token).ConfigureAwait(false);
            }

            if (socket.SubProtocol != ReportWebSocketSettings.Subprotocol)
            {
                throw new ReporterFailure("websocket_protocol_error");
            }

            session = new ReportWebSocketSession(socket, invoker, settings.MaxMessageBytes);
            using var readyDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            readyDeadline.CancelAfter(TimeSpan.FromSeconds(ReadyTimeoutSeconds));
            var first = await session.ReadRawMessageAsync(readyDeadline.Token).ConfigureAwait(false);
            var ready = ParseReady(first);
            return (session, ready);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            if (session is not null)
            {
                await session.DisposeAsync().ConfigureAwait(false);
            }
            else
            {
                socket.Dispose();
                invoker.Dispose();
            }

            throw new TimeoutException("WebSocket connection or ready message timed out.");
        }
        catch
        {
            if (session is not null)
            {
                await session.DisposeAsync().ConfigureAwait(false);
            }
            else
            {
                socket.Dispose();
                invoker.Dispose();
            }

            throw;
        }
    }

    public static byte[] EncodeReport(ReportRequest request)
    {
        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [ReportCanonical.DeviceHeader] = request.Header(ReportCanonical.DeviceHeader) ?? string.Empty,
            [ReportCanonical.TimestampHeader] = request.Header(ReportCanonical.TimestampHeader) ?? string.Empty,
            [ReportCanonical.NonceHeader] = request.Header(ReportCanonical.NonceHeader) ?? string.Empty,
            [ReportCanonical.SignatureHeader] = request.Header(ReportCanonical.SignatureHeader) ?? string.Empty,
        };
        var data = JsonSerializer.SerializeToUtf8Bytes(new
        {
            type = "report",
            headers,
            body = StrictUtf8.GetString(request.Body),
        });
        return data;
    }

    public async Task SendMessageAsync(ReadOnlyMemory<byte> data, int timeoutMs, CancellationToken cancellationToken)
    {
        if (data.Length > MaxMessageBytes)
        {
            throw new InvalidDataException("WebSocket report exceeds the negotiated message limit.");
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromMilliseconds(timeoutMs));
        try
        {
            await _socket.SendAsync(data, WebSocketMessageType.Text, endOfMessage: true, deadline.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("WebSocket send timed out.");
        }
    }

    public async Task<WebSocketMessage> ReadMessageAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var data = await ReadRawMessageAsync(cancellationToken).ConfigureAwait(false);
            if (ParseServiceMessage(data) is { } message)
            {
                return message;
            }
        }
    }

    internal static WebSocketMessage? ParseServiceMessage(byte[] data)
    {
        using var document = ParseObject(data);
        var root = document.RootElement;
        if (!root.TryGetProperty("type", out var typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException("Missing WebSocket service message type.");
        }

        var type = typeElement.GetString();
        if (string.IsNullOrEmpty(type))
        {
            throw new InvalidDataException("Missing WebSocket service message type.");
        }

        return type switch
        {
            "ack" => new WebSocketMessage.Ack(ParseAck(root)),
            "error" => new WebSocketMessage.Error(ParseError(root)),
            _ => null,
        };
    }

    public void Abort() => _socket.Abort();

    public async Task CloseAsync(CancellationToken cancellationToken)
    {
        if (_socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
        {
            await _socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "client_stop", cancellationToken)
                .ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _lifetime.Cancel();
        _socket.Abort();
        try
        {
            await _reader.ConfigureAwait(false);
        }
        catch
        {
        }

        _incoming.Writer.TryComplete();
        _socket.Dispose();
        _invoker.Dispose();
        _lifetime.Dispose();
    }

    private async Task<byte[]> ReadRawMessageAsync(CancellationToken cancellationToken)
    {
        try
        {
            var bytes = await _incoming.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);
            if (bytes.Length > MaxMessageBytes)
            {
                throw new InvalidDataException("WebSocket message exceeds the negotiated message limit.");
            }

            return bytes;
        }
        catch (ChannelClosedException error)
        {
            throw new WebSocketException("WebSocket receive loop stopped.", error.InnerException ?? error);
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var buffer = new ArrayBufferWriter<byte>(ReceiveChunkBytes);
                WebSocketMessageType? messageType = null;
                var startedAt = Stopwatch.GetTimestamp();
                while (true)
                {
                    var memory = buffer.GetMemory(ReceiveChunkBytes);
                    var result = await _socket.ReceiveAsync(memory, cancellationToken).ConfigureAwait(false);
                    buffer.Advance(result.Count);
                    messageType ??= result.MessageType;
                    if (messageType != result.MessageType)
                    {
                        throw new InvalidDataException("Fragmented WebSocket message changed type.");
                    }

                    if (buffer.WrittenCount > MaxMessageBytes)
                    {
                        throw new InvalidDataException("WebSocket message exceeds the negotiated message limit.");
                    }

                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        throw new ReportWebSocketCloseException(_socket.CloseStatus, _socket.CloseStatusDescription);
                    }

                    if (result.EndOfMessage)
                    {
                        break;
                    }

                    if (Stopwatch.GetElapsedTime(startedAt) > TimeSpan.FromSeconds(10))
                    {
                        throw new InvalidDataException("Fragmented WebSocket message timed out.");
                    }
                }

                if (messageType != WebSocketMessageType.Text)
                {
                    throw new InvalidDataException("Binary WebSocket messages are not supported.");
                }

                if (buffer.WrittenSpan.StartsWith(Utf8Bom))
                {
                    throw new InvalidDataException("WebSocket text messages must not contain a UTF-8 BOM.");
                }

                _ = StrictUtf8.GetString(buffer.WrittenSpan);
                await _incoming.Writer.WriteAsync(buffer.WrittenMemory.ToArray(), cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            _incoming.Writer.TryComplete(error);
        }
    }

    private static WebSocketReady ParseReady(byte[] data)
    {
        using var document = ParseObject(data);
        var root = document.RootElement;
        if (ReadString(root, "type") != "ready"
            || ReadString(root, "protocol") != ReportDiscovery.ProtocolName
            || ReadInteger(root, "version", 1, 1) != 1
            || ReadInteger(root, "transportVersion", 1, 1) != 1)
        {
            throw new ReporterFailure("websocket_protocol_error");
        }

        var settings = new ReportWebSocketSettings(
            ReadInteger(root, "minIntervalMs", 10, 1_000),
            ReadInteger(root, "maxInFlight", 1, 64),
            ReadInteger(root, "ackTimeoutMs", 500, 10_000),
            ReadInteger(root, "maxMessageBytes", 32_768, 65_536),
            ReadInteger(root, "pingIntervalSeconds", 10, 60),
            ReadInteger(root, "pongTimeoutSeconds", 5, 30));
        if (settings.PongTimeoutSeconds >= settings.PingIntervalSeconds)
        {
            throw new ReporterFailure("websocket_protocol_error");
        }

        var serverTime = ParseInstant(ReadString(root, "serverTime"));
        return new WebSocketReady(settings, serverTime);
    }

    private static WebSocketAck ParseAck(JsonElement root)
    {
        var run = RequiredObject(root, "run");
        var runId = ReadUuid(run, "id");
        var seq = ReadInteger(run, "seq", 1, int.MaxValue);
        var status = ReadString(root, "status");
        if (status is not ("accepted" or "duplicate"))
        {
            throw new InvalidDataException("Invalid WebSocket acknowledgement status.");
        }

        var hash = ReadString(root, "bodySha256");
        if (hash.Length != 64 || !hash.All(char.IsAsciiHexDigit) || hash != hash.ToLowerInvariant())
        {
            throw new InvalidDataException("Invalid WebSocket acknowledgement body hash.");
        }

        var receivedAt = ParseInstant(ReadString(root, "receivedAt"));
        var acceptedAt = ParseInstant(ReadString(root, "acceptedAt"));
        _ = ReadInteger(root, "processingMs", 0, 900_000);
        if (root.TryGetProperty("rank", out _))
        {
            _ = ReadInteger(root, "rank", 1, int.MaxValue);
        }

        return new WebSocketAck(runId, seq, status, hash, receivedAt, acceptedAt);
    }

    private static WebSocketError ParseError(JsonElement root)
    {
        var httpStatus = ReadInteger(root, "httpStatus", 400, 599);
        var error = RequiredObject(root, "error");
        var code = ReadString(error, "code");
        if (code.Length is 0 or > 64 || !root.TryGetProperty("fatal", out var fatalElement)
            || fatalElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidDataException("Invalid WebSocket error message.");
        }

        string? runId = null;
        int? seq = null;
        if (root.TryGetProperty("run", out var runElement))
        {
            if (runElement.ValueKind == JsonValueKind.Object)
            {
                runId = ReadUuid(runElement, "id");
                seq = ReadInteger(runElement, "seq", 1, int.MaxValue);
            }
            else if (runElement.ValueKind != JsonValueKind.Null)
            {
                throw new InvalidDataException("Invalid WebSocket error run.");
            }
        }

        int? retryAfter = null;
        if (error.TryGetProperty("retryAfterSeconds", out _))
        {
            retryAfter = ReadInteger(error, "retryAfterSeconds", 1, 86_400);
        }

        long? serverTime = null;
        if (error.TryGetProperty("serverTime", out var serverTimeElement))
        {
            if (serverTimeElement.ValueKind != JsonValueKind.Number || !TryReadStrictInteger(serverTimeElement, out var parsed))
            {
                throw new InvalidDataException("Invalid WebSocket error server time.");
            }

            serverTime = parsed;
        }

        return new WebSocketError(runId, seq, httpStatus, code, retryAfter, serverTime, fatalElement.GetBoolean());
    }

    private static JsonDocument ParseObject(byte[] data)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = 32 });
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("Invalid WebSocket JSON.", error);
        }

        if (document.RootElement.ValueKind != JsonValueKind.Object
            || HasDuplicateNames(document.RootElement)
            || HasInvalidSurrogate(document.RootElement))
        {
            document.Dispose();
            throw new InvalidDataException("Invalid or duplicate-member WebSocket JSON.");
        }

        return document;
    }

    private static bool HasDuplicateNames(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name) || HasDuplicateNames(property.Value))
                {
                    return true;
                }
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                if (HasDuplicateNames(item))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static bool HasInvalidSurrogate(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in value.EnumerateObject())
            {
                if (HasUnpairedSurrogate(property.Name) || HasInvalidSurrogate(property.Value))
                {
                    return true;
                }
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                if (HasInvalidSurrogate(item))
                {
                    return true;
                }
            }
        }
        else if (value.ValueKind == JsonValueKind.String)
        {
            return HasUnpairedSurrogate(value.GetString() ?? string.Empty);
        }

        return false;
    }

    private static bool HasUnpairedSurrogate(string value)
    {
        for (var index = 0; index < value.Length; index++)
        {
            if (char.IsHighSurrogate(value[index]))
            {
                if (index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1]))
                {
                    return true;
                }

                index++;
            }
            else if (char.IsLowSurrogate(value[index]))
            {
                return true;
            }
        }

        return false;
    }

    private static JsonElement RequiredObject(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object
            ? value
            : throw new InvalidDataException($"Missing WebSocket {name} object.");

    private static string ReadString(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : throw new InvalidDataException($"Missing WebSocket {name} string.");

    private static string ReadUuid(JsonElement parent, string name)
    {
        var value = ReadString(parent, name);
        return Guid.TryParseExact(value, "D", out var parsed)
            && parsed.ToString("D", CultureInfo.InvariantCulture) == value
            ? value
            : throw new InvalidDataException($"Invalid WebSocket {name} UUID.");
    }

    private static int ReadInteger(JsonElement parent, string name, int min, int max) =>
        parent.TryGetProperty(name, out var value) && TryReadStrictInteger(value, out var parsed)
            && parsed >= min && parsed <= max
            ? (int)parsed
            : throw new InvalidDataException($"Invalid WebSocket {name} integer.");

    private static bool TryReadStrictInteger(JsonElement value, out long parsed)
    {
        parsed = 0;
        var raw = value.GetRawText();
        var digits = raw.StartsWith("-", StringComparison.Ordinal) ? raw[1..] : raw;
        return value.ValueKind == JsonValueKind.Number && digits.Length > 0 && digits.All(char.IsAsciiDigit)
            && long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out parsed);
    }

    private static DateTimeOffset ParseInstant(string value) =>
        DateTimeOffset.TryParseExact(value, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed
            : throw new InvalidDataException("Invalid WebSocket timestamp.");
}
