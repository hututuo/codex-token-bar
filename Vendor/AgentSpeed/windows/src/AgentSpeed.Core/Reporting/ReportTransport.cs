using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Authentication;

namespace AgentSpeed.Core.Reporting;

/// <summary>A response of any status with its (capped) body; header names lower-case.</summary>
public sealed record ReportHttpResponse(int Status, IReadOnlyDictionary<string, string> Headers, byte[] Body);

public enum ReportTransportErrorKind
{
    /// <summary>A redirect to a non-https URL, or more than three (discovery).</summary>
    DisallowedRedirect,
    TooLarge,
    Timeout,
    Offline,
    Tls,
    Other,
}

/// <summary>Why the user is told a request failed (DESIGN 11): each a localized <c>report.error.*</c> sentence.</summary>
public enum ReportFailure
{
    /// <summary>No connection, the host not found or refusing, a timeout.</summary>
    Unreachable,

    /// <summary>A TLS failure, or a redirect to a non-<c>https</c> URL.</summary>
    Insecure,

    /// <summary>The service answered with a status the client cannot act on (<c>5xx</c>, <c>429</c>, an unexpected <c>3xx</c> …).</summary>
    Unavailable,

    /// <summary>The response could not be read (too large).</summary>
    Response,

    /// <summary>The device key could not be created or used on this computer.</summary>
    Key,
}

/// <summary>A transport failure; <see cref="Reason"/> is short, for the log only, and never contains a URL.</summary>
public sealed class ReportTransportException(ReportTransportErrorKind kind, string reason) : Exception(reason)
{
    public ReportTransportErrorKind Kind { get; } = kind;

    public string Reason => Message;

    /// <summary>What the user is told (DESIGN 11, No internals).</summary>
    public ReportFailure Failure => Kind switch
    {
        ReportTransportErrorKind.DisallowedRedirect or ReportTransportErrorKind.Tls => ReportFailure.Insecure,
        ReportTransportErrorKind.TooLarge => ReportFailure.Response,
        _ => ReportFailure.Unreachable,
    };
}

public static class ReportFailures
{
    public static string Key(ReportFailure failure) => failure switch
    {
        ReportFailure.Unreachable => "report.error.unreachable",
        ReportFailure.Insecure => "report.error.insecure",
        ReportFailure.Unavailable => "report.error.unavailable",
        ReportFailure.Response => "report.error.response",
        _ => "report.error.key",
    };
}

/// <summary>The network seam of live reporting; tests use a scripted transport or the reference server.</summary>
public interface IReportTransport
{
    /// <summary>Discovery <c>GET</c> (REPORTING 3.1): <c>Accept</c>, <c>User-Agent</c>, <c>If-None-Match</c>; up to three <c>https</c> redirects.</summary>
    /// <exception cref="ReportTransportException">The request failed.</exception>
    Task<ReportHttpResponse> GetAsync(Uri url, string? etag, string userAgent, int maxBytes, TimeSpan timeout, CancellationToken cancellationToken = default);

    /// <summary>An API request: never redirected (a <c>3xx</c> comes back as the response).</summary>
    /// <exception cref="ReportTransportException">The request failed.</exception>
    Task<ReportHttpResponse> SendAsync(ReportRequest request, int maxBytes, TimeSpan timeout, CancellationToken cancellationToken = default);
}

/// <summary>
/// REPORTING 2.3 over <see cref="HttpClient"/>: no cookies, credentials, cache or authentication challenges (server trust
/// only), the system proxy, TLS 1.2 or later, no client certificates, no compression, hard size caps and timeouts.
/// </summary>
public sealed class HttpReportTransport : IReportTransport, IDisposable
{
    public const int MaxRedirects = 3;
    private const int ChunkSize = 16 * 1024;

    private readonly HttpClient _http;

    public HttpReportTransport()
        : this(CreateHandler())
    {
    }

    internal HttpReportTransport(HttpMessageHandler handler)
    {
        _http = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<ReportHttpResponse> GetAsync(Uri url, string? etag, string userAgent, int maxBytes, TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        return await Run(async token =>
        {
            var current = url;
            for (var hop = 0; ; hop++)
            {
                using var message = new HttpRequestMessage(HttpMethod.Get, current) { Version = HttpVersion.Version11 };
                message.Headers.TryAddWithoutValidation("User-Agent", userAgent);
                message.Headers.TryAddWithoutValidation("Accept", "application/json");
                if (etag is { Length: > 0 and <= 512 } && etag.All(c => c is >= ' ' and <= '~'))
                {
                    message.Headers.TryAddWithoutValidation("If-None-Match", etag);
                }

                using var response = await _http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                var status = (int)response.StatusCode;
                if (status is 301 or 302 or 303 or 307 or 308 && response.Headers.Location is { } location)
                {
                    var next = location.IsAbsoluteUri ? location : new Uri(current, location);
                    if (hop >= MaxRedirects || next.Scheme != Uri.UriSchemeHttps || next.UserInfo.Length > 0)
                    {
                        throw new ReportTransportException(ReportTransportErrorKind.DisallowedRedirect, "redirect");
                    }

                    current = next;
                    continue;
                }

                return await Read(response, maxBytes, token).ConfigureAwait(false);
            }
        }, deadline, cancellationToken).ConfigureAwait(false);
    }

    public async Task<ReportHttpResponse> SendAsync(ReportRequest request, int maxBytes, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        return await Run(async token =>
        {
            using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url) { Version = HttpVersion.Version11 };
            ByteArrayContent? content = request.Body.Length > 0 ? new ByteArrayContent(request.Body) : null;
            foreach (var (name, value) in request.Headers)
            {
                if (string.Equals(name, "Content-Type", StringComparison.OrdinalIgnoreCase))
                {
                    content?.Headers.TryAddWithoutValidation(name, value);
                }
                else
                {
                    message.Headers.TryAddWithoutValidation(name, value);
                }
            }

            if (content is not null)
            {
                content.Headers.ContentLength = request.Body.Length;
                message.Content = content;
            }

            using var response = await _http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            return await Read(response, maxBytes, token).ConfigureAwait(false);
        }, deadline, cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => _http.Dispose();

    internal static SocketsHttpHandler CreateHandler() => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        DefaultProxyCredentials = null,
        PreAuthenticate = false,
        UseProxy = true,
        AutomaticDecompression = DecompressionMethods.None,
        ActivityHeadersPropagator = null,
        ConnectTimeout = TimeSpan.FromSeconds(15),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        MaxResponseHeadersLength = 64,
        MaxConnectionsPerServer = 2,
        SslOptions = new SslClientAuthenticationOptions
        {
            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            ClientCertificates = null,
            LocalCertificateSelectionCallback = null,
        },
    };

    private static async Task<ReportHttpResponse> Run(Func<CancellationToken, Task<ReportHttpResponse>> body, CancellationTokenSource deadline,
        CancellationToken caller)
    {
        try
        {
            return await body(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!caller.IsCancellationRequested)
        {
            throw new ReportTransportException(ReportTransportErrorKind.Timeout, "timeout");
        }
        catch (HttpRequestException ex)
        {
            throw Classify(ex);
        }
        catch (IOException)
        {
            throw new ReportTransportException(ReportTransportErrorKind.Offline, "connection interrupted");
        }
        catch (AuthenticationException)
        {
            throw new ReportTransportException(ReportTransportErrorKind.Tls, "TLS");
        }
    }

    /// <summary>The error category only: never a URL, a host or a message that could carry one.</summary>
    private static ReportTransportException Classify(HttpRequestException exception)
    {
        if (exception.InnerException is AuthenticationException || exception.HttpRequestError == HttpRequestError.SecureConnectionError)
        {
            return new ReportTransportException(ReportTransportErrorKind.Tls, "TLS");
        }

        return exception.HttpRequestError switch
        {
            HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError =>
                new ReportTransportException(ReportTransportErrorKind.Offline, exception.HttpRequestError.ToString()),
            HttpRequestError.ConfigurationLimitExceeded =>
                new ReportTransportException(ReportTransportErrorKind.TooLarge, "response too large"),
            var error => new ReportTransportException(ReportTransportErrorKind.Other, error.ToString()),
        };
    }

    private static async Task<ReportHttpResponse> Read(HttpResponseMessage response, int maxBytes, CancellationToken token)
    {
        if (response.Content.Headers.ContentLength > maxBytes)
        {
            throw new ReportTransportException(ReportTransportErrorKind.TooLarge, "response too large");
        }

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        Collect(response.Headers, headers);
        Collect(response.Content.Headers, headers);
        var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        await using (stream.ConfigureAwait(false))
        {
            using var buffer = new MemoryStream();
            var chunk = new byte[ChunkSize];
            int read;
            while ((read = await stream.ReadAsync(chunk, token).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + read > maxBytes)
                {
                    throw new ReportTransportException(ReportTransportErrorKind.TooLarge, "response too large");
                }

                buffer.Write(chunk, 0, read);
            }

            return new ReportHttpResponse((int)response.StatusCode, headers, buffer.ToArray());
        }
    }

    private static void Collect(HttpHeaders source, Dictionary<string, string> target)
    {
        foreach (var (name, values) in source.NonValidated)
        {
            target[name.ToLowerInvariant()] = string.Join(", ", values);
        }
    }
}
