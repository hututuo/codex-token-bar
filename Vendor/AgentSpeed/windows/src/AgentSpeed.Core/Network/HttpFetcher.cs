using System.Net;
using System.Net.Http;

namespace AgentSpeed.Core.Network;

/// <summary>One HTTPS <c>GET</c> of NETWORK 1: the request line and only these headers, against a feature's host list.</summary>
/// <param name="AllowedHosts">Hosts the request and every redirect hop may use (HTTPS only).</param>
public sealed record HttpFetchRequest(Uri Url, string UserAgent, int MaxBytes, IReadOnlySet<string> AllowedHosts)
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(15);

    public string Accept { get; init; } = "application/json";

    /// <summary>The <c>ETag</c> the same URL returned before; null sends no <c>If-None-Match</c>.</summary>
    public string? IfNoneMatch { get; init; }

    public TimeSpan Timeout { get; init; } = DefaultTimeout;

    /// <summary><c>AgentSpeed/&lt;version&gt; (Windows)</c>, the only identification a request carries (NETWORK 1).</summary>
    public static string UserAgentFor(string version) => $"AgentSpeed/{version} (Windows)";

    /// <summary>HTTPS on the allowed hosts, default port, no user information.</summary>
    public bool Permits(Uri? url) =>
        url is { IsAbsoluteUri: true } && url.Scheme == Uri.UriSchemeHttps && url.Port == 443 && url.UserInfo.Length == 0
        && url.IdnHost.Length > 0 && AllowedHosts.Contains(url.IdnHost.ToLowerInvariant());
}

/// <summary>A response of any status; a <c>304</c> has an empty body. Bodies of other non-2xx statuses are not read.</summary>
public sealed class HttpFetchResponse
{
    public HttpFetchResponse(int status, byte[]? body = null, string? etag = null, Uri? finalUrl = null)
    {
        Status = status;
        Body = body ?? [];
        ETag = etag;
        FinalUrl = finalUrl;
    }

    public int Status { get; }

    public byte[] Body { get; }

    public string? ETag { get; }

    /// <summary>The URL that answered, after redirects.</summary>
    public Uri? FinalUrl { get; }

    public bool IsSuccess => Status is >= 200 and <= 299;
}

public enum HttpFetchFailure
{
    /// <summary>Not HTTPS, or a host (or redirect hop) outside the feature's list.</summary>
    DisallowedUrl,

    /// <summary>Larger than the feature's cap, by <c>Content-Length</c> or while streaming.</summary>
    TooLarge,

    /// <summary>Timeouts, offline, TLS and other transport failures.</summary>
    Transport,
}

/// <summary>A failed fetch; <see cref="Reason"/> is short and never contains a URL or anything personal.</summary>
public sealed class HttpFetchException : Exception
{
    public HttpFetchException(HttpFetchFailure failure, string reason)
        : base(reason)
    {
        Failure = failure;
    }

    public HttpFetchFailure Failure { get; }

    /// <summary>A short reason for logs and the inline status.</summary>
    public string Reason => Message;

    public static HttpFetchException DisallowedUrl() => new(HttpFetchFailure.DisallowedUrl, "disallowed URL");

    public static HttpFetchException TooLarge() => new(HttpFetchFailure.TooLarge, "response too large");
}

/// <summary>The network seam: the app uses <see cref="HttpClientTransport"/>, tests a scripted transport.</summary>
public interface IHttpTransport
{
    /// <exception cref="HttpFetchException">Disallowed URL, too large, or a transport failure.</exception>
    /// <exception cref="OperationCanceledException">The caller cancelled.</exception>
    Task<HttpFetchResponse> GetAsync(HttpFetchRequest request, CancellationToken cancellationToken = default);
}

/// <summary>
/// NETWORK 1 transport: no cookies, credentials, cache or trace headers, the system proxy, automatic decompression off, a
/// 15 s timeout per request, redirects followed by hand only to <c>https</c> URLs on the request's host list, and a hard
/// byte cap enforced by <c>Content-Length</c> and while streaming.
/// </summary>
public sealed class HttpClientTransport : IHttpTransport, IDisposable
{
    public const int MaxRedirects = 5;

    private const int ChunkSize = 16 * 1024;
    private const int MaxETagLength = 512;

    private readonly HttpClient _http;

    public HttpClientTransport()
        : this(CreateHandler())
    {
    }

    /// <summary>Tests pass an in-process handler; production uses <see cref="CreateHandler"/>.</summary>
    internal HttpClientTransport(HttpMessageHandler handler)
    {
        _http = new HttpClient(handler, disposeHandler: true) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
    }

    public async Task<HttpFetchResponse> GetAsync(HttpFetchRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!request.Permits(request.Url))
        {
            throw HttpFetchException.DisallowedUrl();
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(request.Timeout);
        try
        {
            var current = request.Url;
            for (var hop = 0; ; hop++)
            {
                using var message = Message(request, current);
                using var response = await _http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                    .ConfigureAwait(false);
                var status = (int)response.StatusCode;
                if (IsRedirect(status) && response.Headers.Location is { } location)
                {
                    if (hop >= MaxRedirects)
                    {
                        throw new HttpFetchException(HttpFetchFailure.Transport, "too many redirects");
                    }

                    var next = location.IsAbsoluteUri ? location : new Uri(current, location);
                    if (!request.Permits(next))
                    {
                        throw HttpFetchException.DisallowedUrl();
                    }

                    current = next;
                    continue;
                }

                var etag = ETagOf(response);
                if (status is < 200 or > 299)
                {
                    // Other statuses carry nothing the features use; the body is not read.
                    return new HttpFetchResponse(status, etag: etag, finalUrl: current);
                }

                if (response.Content.Headers.ContentLength > request.MaxBytes)
                {
                    throw HttpFetchException.TooLarge();
                }

                var body = await ReadCappedAsync(response.Content, request.MaxBytes, timeout.Token).ConfigureAwait(false);
                return new HttpFetchResponse(status, body, etag, current);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new HttpFetchException(HttpFetchFailure.Transport, "timeout");
        }
        catch (HttpRequestException ex)
        {
            throw new HttpFetchException(HttpFetchFailure.Transport, Describe(ex));
        }
        catch (IOException)
        {
            throw new HttpFetchException(HttpFetchFailure.Transport, "connection interrupted");
        }
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
        ConnectTimeout = HttpFetchRequest.DefaultTimeout,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        MaxResponseHeadersLength = 64,
    };

    /// <summary>A visible-ASCII header value (no control characters, so nothing can be injected).</summary>
    internal static bool IsHeaderSafe(string? value) =>
        !string.IsNullOrEmpty(value) && value.Length <= MaxETagLength && value.All(c => c is >= ' ' and <= '~');

    private static HttpRequestMessage Message(HttpFetchRequest request, Uri url)
    {
        var message = new HttpRequestMessage(HttpMethod.Get, url) { Version = HttpVersion.Version11 };
        message.Headers.TryAddWithoutValidation("User-Agent", request.UserAgent);
        message.Headers.TryAddWithoutValidation("Accept", request.Accept);
        if (IsHeaderSafe(request.IfNoneMatch))
        {
            message.Headers.TryAddWithoutValidation("If-None-Match", request.IfNoneMatch);
        }

        return message;
    }

    private static bool IsRedirect(int status) => status is 301 or 302 or 303 or 307 or 308;

    private static string? ETagOf(HttpResponseMessage response) =>
        response.Headers.TryGetValues("ETag", out var values) && values.FirstOrDefault() is { } value && IsHeaderSafe(value)
            ? value
            : null;

    private static async Task<byte[]> ReadCappedAsync(HttpContent content, int limit, CancellationToken cancellationToken)
    {
        var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using (stream.ConfigureAwait(false))
        {
            using var buffer = new MemoryStream();
            var chunk = new byte[ChunkSize];
            int read;
            while ((read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + read > limit)
                {
                    throw HttpFetchException.TooLarge();
                }

                buffer.Write(chunk, 0, read);
            }

            return buffer.ToArray();
        }
    }

    /// <summary>The error category only: never a URL, a host or a message that could carry one.</summary>
    private static string Describe(HttpRequestException exception) => exception.HttpRequestError switch
    {
        HttpRequestError.Unknown => "transport error",
        var error => error.ToString(),
    };
}
