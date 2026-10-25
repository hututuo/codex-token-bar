using System.Diagnostics;
using System.Globalization;

namespace AgentSpeed.Core.Reporting;

/// <summary>The outcome of a discovery fetch (REPORTING 3.1, 3.2); DESIGN 11 shows each as one localized sentence.</summary>
public abstract record ReportDiscoveryOutcome
{
    private ReportDiscoveryOutcome()
    {
    }

    public sealed record Document(ReportDiscovery Discovery, string? ETag) : ReportDiscoveryOutcome;

    public sealed record NotModified : ReportDiscoveryOutcome;

    /// <summary>
    /// The URL does not offer this API: <c>404</c>, another <c>4xx</c> except <c>410</c> and <c>429</c>, or a response that is not
    /// an <c>agent-speed-report</c> document — not a JSON object, over 64 KiB (typically a web page), another <c>protocol</c>.
    /// </summary>
    public sealed record NotSupported : ReportDiscoveryOutcome;

    /// <summary>An <c>agent-speed-report</c> document that breaks REPORTING 3.2.</summary>
    public sealed record Invalid : ReportDiscoveryOutcome;

    /// <summary><c>410</c>: the service stopped for good (REPORTING 8.3).</summary>
    public sealed record Gone : ReportDiscoveryOutcome;

    /// <summary>Anything else: try again later.</summary>
    public sealed record Failed(ReportFailure Failure) : ReportDiscoveryOutcome;
}

/// <summary>A reply, or the reason the request did not get one.</summary>
public readonly record struct ReportCallResult(ReportReply? Reply, ReportTransportException? Error)
{
    public bool HasReply => Reply is not null;
}

/// <summary>
/// The endpoints of REPORTING 2.4 for one service, over a transport. Every call returns a validated reply or a transport
/// error; nothing here retries (the scheduler and the controller decide).
/// </summary>
public sealed class ReportApi(IReportTransport transport, string userAgent)
{
    public static readonly TimeSpan DiscoveryTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan ApiTimeout = TimeSpan.FromSeconds(10);
    public const int ApiMaxBytes = 16_384;

    public string UserAgent { get; } = userAgent;

    public async Task<ReportDiscoveryOutcome> DiscoverAsync(ReportServiceUrl service, string? etag = null, CancellationToken cancellationToken = default)
    {
        ReportHttpResponse response;
        try
        {
            response = await transport.GetAsync(service.DiscoveryUrl, etag, UserAgent, ReportDiscovery.MaxBytes, DiscoveryTimeout, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (ReportTransportException error)
        {
            ReportLog.Write($"discovery {service.Host} failed: {error.Reason}");
            // A body over 64 KiB is not a discovery document (REPORTING 3.2): usually the site's web page.
            return error.Kind == ReportTransportErrorKind.TooLarge
                ? new ReportDiscoveryOutcome.NotSupported()
                : new ReportDiscoveryOutcome.Failed(error.Failure);
        }

        ReportLog.Write($"GET {service.Host} discovery -> {response.Status} {response.Body.Length} bytes");
        return DiscoveryOutcome(response.Status, response.Body, etag, response.Headers.GetValueOrDefault("etag"), service);
    }

    /// <summary>REPORTING 3.1 and 3.2 for one response.</summary>
    public static ReportDiscoveryOutcome DiscoveryOutcome(int status, byte[] body, string? etag, string? responseETag, ReportServiceUrl service)
    {
        switch (status)
        {
            case 200:
                if (ReportDiscovery.Parse(body, service, out var problem) is { } document)
                {
                    return new ReportDiscoveryOutcome.Document(document, responseETag is { Length: <= 512 } tag ? tag : null);
                }

                ReportLog.Write($"discovery invalid: {problem}");
                return problem!.IsOtherDocument ? new ReportDiscoveryOutcome.NotSupported() : new ReportDiscoveryOutcome.Invalid();
            case 304:
                return etag is null ? new ReportDiscoveryOutcome.Failed(ReportFailure.Unavailable) : new ReportDiscoveryOutcome.NotModified();
            case 410:
                return new ReportDiscoveryOutcome.Gone();
            case 429:
                return new ReportDiscoveryOutcome.Failed(ReportFailure.Unavailable);
            case >= 400 and <= 499:
                return new ReportDiscoveryOutcome.NotSupported();
            default:
                return new ReportDiscoveryOutcome.Failed(ReportFailure.Unavailable);
        }
    }

    /// <summary>Sends one signed request and parses the answer (16 KiB cap, 10 s timeout).</summary>
    public async Task<ReportCallResult> CallAsync(ReportRequest request, CancellationToken cancellationToken = default)
    {
        var started = Stopwatch.GetTimestamp();
        try
        {
            var response = await transport.SendAsync(request, ApiMaxBytes, ApiTimeout, cancellationToken).ConfigureAwait(false);
            var reply = ReportReply.Parse(response.Status, response.Headers, response.Body, DateTimeOffset.UtcNow);
            var ms = (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            ReportLog.Write(string.Create(CultureInfo.InvariantCulture,
                $"{request} -> {response.Status} {reply.Code ?? string.Empty} sent {request.Body.Length} received {response.Body.Length} {ms} ms {reply.LogMessage ?? string.Empty}"));
            return new ReportCallResult(reply, null);
        }
        catch (ReportTransportException error)
        {
            ReportLog.Write($"{request} failed: {error.Reason}");
            return new ReportCallResult(null, error);
        }
    }
}

/// <summary>The bodies the client writes besides reports (REPORTING 4).</summary>
public static class ReportDocuments
{
    public static byte[] Registration(string deviceId, string username, ReportPublicKey publicKey, ReportClientInfo client, bool transfer = false)
    {
        var members = new List<(string, ReportJson)>
        {
            ("schema", ReportJson.Of(1)),
            ("deviceId", ReportJson.Of(deviceId)),
            ("username", ReportJson.Of(username)),
            ("publicKey", publicKey.Jwk),
            ("client", client.Json),
        };
        if (transfer)
        {
            members.Add(("transfer", ReportJson.Of(true)));
        }

        return ReportJson.Object(members).ToCompactBytes();
    }

    public static byte[] Rename(string username) => ReportJson.Object(("username", ReportJson.Of(username))).ToCompactBytes();

    public static byte[] Rotation(ReportPublicKey publicKey) => ReportJson.Object(("publicKey", publicKey.Jwk)).ToCompactBytes();
}

/// <summary>Endpoint paths under <c>api</c> (REPORTING 2.4).</summary>
public static class ReportEndpoint
{
    public const string Devices = "/v1/devices";
    public const string Reports = "/v1/reports";

    public static string Device(string id) => $"/v1/devices/{id}";

    public static string Key(string id) => $"/v1/devices/{id}/key";
}

/// <summary>
/// Request logging (REPORTING 2.3): method, host, path, status, error code, sizes and timing — never bodies, signatures or
/// API keys. The app points <see cref="Sink"/> at its log.
/// </summary>
public static class ReportLog
{
    public static Action<string>? Sink { get; set; }

    public static void Write(string line) => Sink?.Invoke("report: " + line);
}
