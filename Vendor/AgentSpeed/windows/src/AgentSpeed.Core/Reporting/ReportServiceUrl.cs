using System.Globalization;
using System.Text;

namespace AgentSpeed.Core.Reporting;

public enum ReportUrlProblem
{
    Invalid,
    NotHttps,
}

/// <summary>A normalized service URL (REPORTING 2.1, 2.2).</summary>
public sealed class ReportServiceUrl : IEquatable<ReportServiceUrl>
{
    public const int MaxLength = 2048;
    public const string DiscoveryPath = "/.well-known/agent-speed-report";
    private static readonly HashSet<string> LoopbackHosts = new(StringComparer.Ordinal) { "127.0.0.1", "[::1]", "localhost" };
    private static readonly IdnMapping Idn = new() { UseStd3AsciiRules = true, AllowUnassigned = false };

    private ReportServiceUrl(string scheme, string host, int? port, string path)
    {
        Scheme = scheme;
        Host = host;
        Port = port;
        Path = path;
        Text = $"{scheme}://{Authority}{path}";
    }

    /// <summary><c>scheme://host[:port][path]</c>: lower-case host (IDNA A-labels), the port only when not the default, no trailing <c>/</c>.</summary>
    public string Text { get; }

    /// <summary><c>https</c>, or <c>http</c> for a loopback test server.</summary>
    public string Scheme { get; }

    /// <summary>The host alone (IPv6 in brackets), as shown to the user.</summary>
    public string Host { get; }

    public int? Port { get; }

    public string Path { get; }

    /// <summary><c>http</c> to <c>127.0.0.1</c>, <c>[::1]</c> or <c>localhost</c>: unencrypted local testing (REPORTING 2.2).</summary>
    public bool IsLoopbackHttp => Scheme == "http";

    /// <summary><c>host[:port]</c> as in REPORTING 5.3 line 3.</summary>
    public string Authority => Port is { } port ? $"{Host}:{port.ToString(CultureInfo.InvariantCulture)}" : Host;

    /// <summary><c>scheme://authority</c>, the key of a stored service identity.</summary>
    public string Origin => $"{Scheme}://{Authority}";

    /// <summary>REPORTING 2.1 step 3.</summary>
    public Uri DiscoveryUrl => new(Text + DiscoveryPath, UriKind.Absolute);

    /// <summary>Endpoint URL <c>{api}{path}</c> where the path starts with <c>/v1/</c> (REPORTING 2.4).</summary>
    public Uri Endpoint(string path)
    {
        if (!path.StartsWith("/v1/", StringComparison.Ordinal))
        {
            throw new ArgumentException("Endpoint paths start with /v1/.", nameof(path));
        }

        return new Uri(Text + path, UriKind.Absolute);
    }

    /// <summary>REPORTING 2.1: trims, prefixes <c>https://</c> when no scheme is given, then normalizes.</summary>
    public static ReportServiceUrl? Parse(string? input) => TryParse(input, out var url, out _) ? url : null;

    public static bool TryParse(string? input, out ReportServiceUrl? url, out ReportUrlProblem problem)
    {
        url = null;
        var trimmed = (input ?? string.Empty).Trim();
        if (trimmed.Length == 0)
        {
            problem = ReportUrlProblem.Invalid;
            return false;
        }

        return Normalize(HasScheme(trimmed) ? trimmed : "https://" + trimmed, out url, out problem);
    }

    /// <summary>The discovery document's <c>api</c> (REPORTING 3.2): http only when the document came over loopback http.</summary>
    public static ReportServiceUrl? ParseApi(string text, bool discoveryIsLoopbackHttp)
    {
        if (!HasScheme(text) || !Normalize(text, out var api, out _) || api is null)
        {
            return null;
        }

        return api.IsLoopbackHttp && !discoveryIsLoopbackHttp ? null : api;
    }

    public bool Equals(ReportServiceUrl? other) => other is not null && string.Equals(Text, other.Text, StringComparison.Ordinal);

    public override bool Equals(object? obj) => obj is ReportServiceUrl other && Equals(other);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Text);

    public override string ToString() => Text;

    internal static bool HasScheme(string text)
    {
        var separator = text.IndexOf("://", StringComparison.Ordinal);
        if (separator <= 0 || !char.IsAsciiLetter(text[0]))
        {
            return false;
        }

        for (var i = 0; i < separator; i++)
        {
            var c = text[i];
            if (!(char.IsAsciiLetterOrDigit(c) || c is '+' or '-' or '.'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool Normalize(string text, out ReportServiceUrl? url, out ReportUrlProblem problem)
    {
        url = null;
        problem = ReportUrlProblem.Invalid;
        if (!ReportUrls.IsCleanText(text) || text.Contains('\\', StringComparison.Ordinal) || !HasValidPercentEscapes(text) || !HasScheme(text))
        {
            return false;
        }

        var separator = text.IndexOf("://", StringComparison.Ordinal);
        var scheme = text[..separator].ToLowerInvariant();
        var rest = text[(separator + 3)..];
        var authorityEnd = rest.IndexOfAny(['/', '?', '#']);
        var authority = authorityEnd < 0 ? rest : rest[..authorityEnd];
        var remainder = authorityEnd < 0 ? string.Empty : rest[authorityEnd..];
        if (remainder.Contains('?', StringComparison.Ordinal) || remainder.Contains('#', StringComparison.Ordinal)
            || authority.Contains('@', StringComparison.Ordinal) || !SplitAuthority(authority, out var rawHost, out var port))
        {
            return false;
        }

        if (HostOf(rawHost) is not { } host || !IsValidHost(host))
        {
            return false;
        }

        switch (scheme)
        {
            case "https":
                break;
            case "http" when LoopbackHosts.Contains(host):
                break;
            default:
                problem = ReportUrlProblem.NotHttps;
                return false;
        }

        if (port is { } p && p == (scheme == "https" ? 443 : 80))
        {
            port = null;
        }

        var path = EncodePath(remainder).TrimEnd('/');
        if ((path.Length > 0 && path[0] != '/') || HasDotSegment(path))
        {
            return false;
        }

        var candidate = new ReportServiceUrl(scheme, host, port, path);
        if (candidate.Text.EnumerateRunes().Count() > MaxLength
            || !Uri.TryCreate(candidate.Text + DiscoveryPath, UriKind.Absolute, out var parsed)
            || !string.Equals(ReportUrls.Authority(parsed), candidate.Authority, StringComparison.Ordinal))
        {
            return false;
        }

        url = candidate;
        return true;
    }

    private static bool SplitAuthority(string authority, out string host, out int? port)
    {
        host = authority;
        port = null;
        string? portText = null;
        if (authority.StartsWith('['))
        {
            var close = authority.IndexOf(']', StringComparison.Ordinal);
            if (close < 0)
            {
                return false;
            }

            host = authority[..(close + 1)];
            var after = authority[(close + 1)..];
            if (after.Length > 0)
            {
                if (after[0] != ':')
                {
                    return false;
                }

                portText = after[1..];
            }
        }
        else
        {
            var colon = authority.IndexOf(':', StringComparison.Ordinal);
            if (colon >= 0)
            {
                host = authority[..colon];
                portText = authority[(colon + 1)..];
            }
        }

        if (portText is not null)
        {
            if (portText.Length is 0 or > 5 || !portText.All(char.IsAsciiDigit)
                || !int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value is < 1 or > 65535)
            {
                return false;
            }

            port = value;
        }

        return host.Length > 0;
    }

    /// <summary>Lower-case ASCII (IDNA A-labels for international names); IPv6 literals stay in brackets.</summary>
    private static string? HostOf(string raw)
    {
        if (raw.StartsWith('['))
        {
            return raw.ToLowerInvariant();
        }

        if (raw.All(char.IsAscii))
        {
            return raw.ToLowerInvariant();
        }

        try
        {
            return Idn.GetAscii(raw).ToLowerInvariant();
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    /// <summary>A DNS name of LDH labels (after IDNA), a dotted IPv4 address, or an IPv6 address in brackets.</summary>
    internal static bool IsValidHost(string host)
    {
        if (host.Length is 0 or > 253)
        {
            return false;
        }

        if (host.StartsWith('['))
        {
            var inner = host[1..^1];
            return host.EndsWith(']') && inner.Contains(':', StringComparison.Ordinal) && inner.All(c => char.IsAsciiHexDigit(c) || c is ':' or '.');
        }

        foreach (var label in host.Split('.'))
        {
            if (label.Length is < 1 or > 63 || label[0] == '-' || label[^1] == '-'
                || !label.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasValidPercentEscapes(string text)
    {
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '%')
            {
                if (i + 2 >= text.Length || !char.IsAsciiHexDigit(text[i + 1]) || !char.IsAsciiHexDigit(text[i + 2]))
                {
                    return false;
                }

                i += 2;
            }
        }

        return true;
    }

    /// <summary>The path as typed, with characters a path may not carry percent-encoded (UTF-8).</summary>
    private static string EncodePath(string path)
    {
        var builder = new StringBuilder(path.Length);
        Span<byte> bytes = stackalloc byte[4];
        foreach (var rune in path.EnumerateRunes())
        {
            if (rune.IsAscii && IsPathCharacter((char)rune.Value))
            {
                builder.Append((char)rune.Value);
                continue;
            }

            var count = rune.EncodeToUtf8(bytes);
            for (var i = 0; i < count; i++)
            {
                builder.Append('%').Append(bytes[i].ToString("X2", CultureInfo.InvariantCulture));
            }
        }

        return builder.ToString();
    }

    private static bool IsPathCharacter(char c) =>
        char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '_' or '~' or '!' or '$' or '&' or '\'' or '(' or ')' or '*' or '+' or ','
            or ';' or '=' or ':' or '@' or '/' or '%';

    /// <summary><c>.</c> and <c>..</c> segments (also percent-encoded) are refused so the signed path is the path sent (REPORTING 5.3).</summary>
    private static bool HasDotSegment(string path) =>
        path.Split('/').Any(segment =>
        {
            var decoded = segment.Replace("%2e", ".", StringComparison.OrdinalIgnoreCase);
            return decoded is "." or "..";
        });
}

public static class ReportUrls
{
    /// <summary>
    /// REPORTING 5.3 line 3: lower-case host (IDNA A-labels; IPv6 in brackets), <c>:port</c> only when not the scheme default.
    /// </summary>
    public static string Authority(Uri url)
    {
        var host = url.HostNameType == UriHostNameType.IPv6 ? url.Host : url.IdnHost;
        host = host.ToLowerInvariant();
        if (url.HostNameType == UriHostNameType.IPv6 && !host.StartsWith('['))
        {
            host = $"[{host}]";
        }

        return url.IsDefaultPort ? host : $"{host}:{url.Port.ToString(CultureInfo.InvariantCulture)}";
    }

    /// <summary>REPORTING 5.3 line 4: path and query exactly as sent on the request line, <c>/</c> when empty.</summary>
    public static string RequestPath(Uri url) => url.PathAndQuery is { Length: > 0 } path ? path : "/";

    /// <summary>
    /// A link of the schema's <c>$defs/httpsUrl</c> (REPORTING 2.2, 2.3): always <c>https</c>, no user information, at most 2048
    /// code points, no white space, control or format characters. Returns the link as given, or null.
    /// </summary>
    public static string? HttpsLink(string? text)
    {
        if (text is null || text.EnumerateRunes().Count() > ReportServiceUrl.MaxLength || !IsCleanText(text)
            || !text.StartsWith("https://", StringComparison.Ordinal))
        {
            return null;
        }

        var rest = text[8..];
        var end = rest.IndexOfAny(['/', '?', '#']);
        var authority = end < 0 ? rest : rest[..end];
        if (authority.Length == 0 || authority.Contains('@', StringComparison.Ordinal) || (end >= 0 && rest[end] != '/'))
        {
            return null;
        }

        return Uri.TryCreate(text, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps && url.Host.Length > 0 ? text : null;
    }

    /// <summary>No white space, control or format characters anywhere.</summary>
    public static bool IsCleanText(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                return false;
            }

            switch (Rune.GetUnicodeCategory(rune))
            {
                case UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator
                    or UnicodeCategory.SpaceSeparator or UnicodeCategory.Surrogate:
                    return false;
            }
        }

        return true;
    }
}
