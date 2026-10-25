using System.Globalization;
using System.Security.Cryptography;

namespace AgentSpeed.Core.Reporting;

/// <summary>Unpadded base64url (RFC 4648 §5) as REPORTING 5.2 requires it: canonical, no padding, zero trailing bits.</summary>
public static class Base64Url
{
    public static string Encode(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Null for another alphabet, padding, a length of 1 mod 4 or non-zero trailing bits.</summary>
    public static byte[]? Decode(string? text)
    {
        if (text is null || text.Length % 4 == 1 || !text.All(IsAlphabet))
        {
            return null;
        }

        var standard = text.Replace('-', '+').Replace('_', '/') + new string('=', (4 - text.Length % 4) % 4);
        try
        {
            var data = Convert.FromBase64String(standard);
            return Encode(data) == text ? data : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static bool IsAlphabet(char c) => c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '_';
}

public static class ReportHash
{
    /// <summary>SHA-256 as 64 lower-case hexadecimal digits (REPORTING 5.3 line 8).</summary>
    public static string Sha256Hex(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));
}

/// <summary><c>YYYY-MM-DDTHH:MM:SS.sssZ</c> in UTC (REPORTING 6.3 <c>sentAt</c>).</summary>
public static class ReportInstant
{
    public static string Format(long unixMs)
    {
        var clamped = Math.Clamp(unixMs, 0, 253_402_300_799_999);
        return DateTimeOffset.FromUnixTimeMilliseconds(clamped).UtcDateTime
            .ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'", CultureInfo.InvariantCulture);
    }
}
