using System.Globalization;
using System.Text.Json;

namespace AgentSpeed.Core.Reporting;

public sealed record ReportProfileAvatar(string Url, string Sha256, int Width, int Height);
public sealed record ReportProfileDevice(string DeviceId, string Platform, bool IsCurrent, bool Online);
public sealed record ReportProfile(string? SharedUserId, string DisplayName, ReportProfileAvatar? Avatar, IReadOnlyList<ReportProfileDevice> Devices);
public sealed record ReportPairing(string Id, string State, DateTimeOffset ExpiresAt, ReportProfileDevice? Claimant, string? Code)
{
    public override string ToString() => $"ReportPairing {{ State = {State}, ExpiresAt = {ExpiresAt:O} }}";
}

public static class ReportProfileJson
{
    public const int MaxBytes = 65_536;
    public static ReportProfile? Profile(ReadOnlySpan<byte> bytes, ReportUsernameRules rules)
    {
        if (bytes.Length > MaxBytes) return null;
        try
        {
            using var json = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("sharedUserId", out var user)
                || (user.ValueKind != JsonValueKind.Null && !ReportCanonical.IsDeviceId(Text(user)))
                || !root.TryGetProperty("displayName", out var name) || Text(name) is not { } displayName
                || ReportUsername.Validate(displayName, rules) is not null
                || !root.TryGetProperty("devices", out var devices) || devices.ValueKind != JsonValueKind.Array || devices.GetArrayLength() > 32)
                return null;
            var list = new List<ReportProfileDevice>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var device in devices.EnumerateArray())
            {
                var value = Device(device, requireFlags: true);
                if (value is null || !seen.Add(value.DeviceId)) return null;
                list.Add(value);
            }
            if (list.Count(d => d.IsCurrent) > 1) return null;
            ReportProfileAvatar? avatar = null;
            if (!root.TryGetProperty("avatar", out var image)) return null;
            if (image.ValueKind != JsonValueKind.Null)
            {
                if (image.ValueKind != JsonValueKind.Object || String(image, "url") is not { } url || ReportUrls.HttpsLink(url) is null
                    || String(image, "sha256") is not { Length: 64 } sha || sha.Any(c => !char.IsAsciiHexDigitLower(c))
                    || String(image, "contentType") != "image/png" || Integer(image, "width") != 256 || Integer(image, "height") != 256) return null;
                avatar = new(url, sha, 256, 256);
            }
            return new(Text(user), displayName, avatar, list);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

    public static ReportPairing? Pairing(ReadOnlySpan<byte> bytes, DateTimeOffset? now = null)
    {
        if (bytes.Length > MaxBytes) return null;
        try
        {
            using var json = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = json.RootElement;
            var state = root.ValueKind == JsonValueKind.Object ? String(root, "state") : null;
            if (root.ValueKind != JsonValueKind.Object || String(root, "id") is not { } id || !ReportCanonical.IsDeviceId(id)
                || state is not ("waiting" or "pending" or "approved" or "cancelled" or "expired")
                || String(root, "expiresAt") is not { } expires || expires.Length > 40
                || !DateTimeOffset.TryParseExact(expires, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var expiresAt)
                || expiresAt - (now ?? DateTimeOffset.UtcNow) > TimeSpan.FromMinutes(11)) return null;
            ReportProfileDevice? claimant = null;
            if (root.TryGetProperty("claimant", out var device) && device.ValueKind != JsonValueKind.Null)
            {
                claimant = Device(device, requireFlags: false);
                if (claimant is null) return null;
            }
            var code = String(root, "code");
            if (code is not null && NormalizeCode(code) is null) return null;
            if (state == "pending" && claimant is null) return null;
            return new(id, state, expiresAt, claimant, code);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

    public static string? NormalizeCode(string? code)
    {
        if (code is null || code.Length > 32) return null;
        var value = code.Replace("-", string.Empty, StringComparison.Ordinal).ToUpperInvariant();
        return value.Length == 12 && value.All(c => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".Contains(c, StringComparison.Ordinal)) ? value : null;
    }

    private static ReportProfileDevice? Device(JsonElement value, bool requireFlags)
    {
        if (value.ValueKind != JsonValueKind.Object || String(value, "deviceId") is not { } id || !ReportCanonical.IsDeviceId(id)
            || String(value, "platform") is not { } platform || platform is not ("macOS" or "Windows")) return null;
        if (requireFlags && (!Bool(value, "isCurrent", out _) || !Bool(value, "online", out _))) return null;
        Bool(value, "isCurrent", out var current);
        Bool(value, "online", out var online);
        return new(id, platform, current, online);
    }
    private static bool Bool(JsonElement root, string name, out bool value)
    {
        value = false;
        if (!root.TryGetProperty(name, out var item) || item.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = item.GetBoolean(); return true;
    }
    private static string? Text(JsonElement value) => value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static string? String(JsonElement root, string name) => root.TryGetProperty(name, out var value) ? Text(value) : null;
    private static int? Integer(JsonElement root, string name) => root.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;
}

public sealed class ReportProfileApi(IReportTransport transport)
{
    public async Task<ReportHttpResponse?> SendAsync(ReportRequest request, bool avatar, CancellationToken cancellationToken)
    {
        try
        {
            return await transport.SendAsync(request, avatar ? ReportAvatarImage.MaxPngBytes : ReportProfileJson.MaxBytes,
                ReportApi.ApiTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (ReportTransportException) { return null; }
    }
}
