using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace AgentSpeed.Core.Reporting;

/// <summary>One signed API request (REPORTING 2.3, 5). Headers keep their order; the body is sent exactly as signed.</summary>
public sealed record ReportRequest(string Method, Uri Url, IReadOnlyList<KeyValuePair<string, string>> Headers, byte[] Body)
{
    public string? Header(string name) =>
        Headers.FirstOrDefault(h => string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase)) is { Key: not null } h ? h.Value : null;

    /// <summary>Method, host and path only: never headers, signatures, the API key or the body (REPORTING 2.3).</summary>
    public override string ToString() => $"{Method} {ReportUrls.Authority(Url)}{ReportUrls.RequestPath(Url)}";
}

/// <summary>The canonical string of REPORTING 5.3 and the header rules of 5.2.</summary>
public static class ReportCanonical
{
    public const string Label = "AGENTSPEED-V1";
    public const string DeviceHeader = "X-AgentSpeed-Device";
    public const string TimestampHeader = "X-AgentSpeed-Timestamp";
    public const string NonceHeader = "X-AgentSpeed-Nonce";
    public const string SignatureHeader = "X-AgentSpeed-Signature";
    public const string NewKeySignatureHeader = "X-AgentSpeed-New-Key-Signature";

    /// <summary>Eight lines joined by a line feed, no final line feed.</summary>
    public static string Build(string method, string authority, string path, string timestamp, string nonce, string deviceId,
        ReadOnlySpan<byte> body) =>
        string.Join('\n', Label, method, authority, path, timestamp, nonce, deviceId, ReportHash.Sha256Hex(body));

    /// <summary>The first missing or malformed signature header (names in any case), or null (REPORTING 5.2).</summary>
    public static string? MalformedHeader(IReadOnlyDictionary<string, string> headers)
    {
        var lower = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in headers)
        {
            lower[key.ToLowerInvariant()] = value;
        }

        string Get(string name) => lower.GetValueOrDefault(name.ToLowerInvariant()) ?? string.Empty;
        if (!IsDeviceId(Get(DeviceHeader)))
        {
            return DeviceHeader;
        }

        if (!IsTimestamp(Get(TimestampHeader)))
        {
            return TimestampHeader;
        }

        if (Base64Url.Decode(Get(NonceHeader)) is not { Length: 16 })
        {
            return NonceHeader;
        }

        return IsSignature(Get(SignatureHeader)) ? null : SignatureHeader;
    }

    /// <summary>86 canonical base64url characters that decode to 64 bytes.</summary>
    public static bool IsSignature(string text) => text.Length == 86 && Base64Url.Decode(text) is { Length: 64 };

    /// <summary>A lower-case version-4 UUID.</summary>
    public static bool IsDeviceId(string? text)
    {
        if (text is not { Length: 36 })
        {
            return false;
        }

        for (var i = 0; i < 36; i++)
        {
            var c = text[i];
            var ok = i switch
            {
                8 or 13 or 18 or 23 => c == '-',
                14 => c == '4',
                19 => c is '8' or '9' or 'a' or 'b',
                _ => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'),
            };
            if (!ok)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsTimestamp(string text) => text.Length == 10 && text[0] != '0' && text.All(char.IsAsciiDigit);

    /// <summary>A fresh lower-case version-4 UUID (device ids, run ids) from the system's cryptographic generator.</summary>
    public static string NewUuid()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        var hex = Convert.ToHexStringLower(bytes);
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
    }

    /// <summary>16 bytes from the system's cryptographic generator (REPORTING 5.2).</summary>
    public static string NewNonce()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        return Base64Url.Encode(bytes);
    }
}

/// <summary>
/// Builds the requests of one device (REPORTING 2.3, 5.2): the fixed headers, the four signature headers and, when the
/// user entered one, the API key.
/// </summary>
public sealed record ReportRequestBuilder(string UserAgent, string DeviceId, string? ApiKey)
{
    /// <param name="timestamp">Unix seconds, the session's clock correction applied.</param>
    /// <param name="newKey">Adds the rotation header (REPORTING 4.5).</param>
    /// <exception cref="CryptographicException">A key cannot sign.</exception>
    public ReportRequest Make(string method, Uri url, byte[] body, IReportSigner signer, long timestamp, string? nonce = null,
        IReportSigner? newKey = null)
    {
        var stamp = timestamp.ToString(CultureInfo.InvariantCulture);
        nonce ??= ReportCanonical.NewNonce();
        var canonical = Encoding.UTF8.GetBytes(ReportCanonical.Build(method, ReportUrls.Authority(url), ReportUrls.RequestPath(url), stamp,
            nonce, DeviceId, body));
        var headers = new List<KeyValuePair<string, string>>
        {
            new("User-Agent", UserAgent),
            new("Accept", "application/json"),
        };
        if (body.Length > 0)
        {
            headers.Add(new("Content-Type", "application/json"));
        }

        headers.Add(new(ReportCanonical.DeviceHeader, DeviceId));
        headers.Add(new(ReportCanonical.TimestampHeader, stamp));
        headers.Add(new(ReportCanonical.NonceHeader, nonce));
        headers.Add(new(ReportCanonical.SignatureHeader, Base64Url.Encode(signer.Sign(canonical))));
        if (newKey is not null)
        {
            headers.Add(new(ReportCanonical.NewKeySignatureHeader, Base64Url.Encode(newKey.Sign(canonical))));
        }

        if (ApiKey is not null)
        {
            headers.Add(new("Authorization", "Bearer " + ApiKey));
        }

        return new ReportRequest(method, url, headers, body);
    }

    /// <summary>Never prints the API key (records print their members).</summary>
    public override string ToString() => $"ReportRequestBuilder {{ DeviceId = {DeviceId} }}";
}
