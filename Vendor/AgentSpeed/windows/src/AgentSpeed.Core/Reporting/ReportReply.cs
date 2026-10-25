using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AgentSpeed.Core.Reporting;

/// <summary>
/// A response of the service (REPORTING 8), validated: only known shapes and clamped numbers are kept, and nothing of it
/// is ever shown to the user except through the app's own strings.
/// </summary>
public sealed record ReportReply(int Status)
{
    private static readonly HashSet<string> SuccessStatuses = new(StringComparer.Ordinal)
    {
        "created", "exists", "updated", "unchanged", "rotated", "deleted", "accepted", "duplicate",
    };

    /// <summary><c>status</c> of a success body.</summary>
    public string? Result { get; init; }

    public string? DeviceId { get; init; }

    public string? Username { get; init; }

    public string? ProfileUrl { get; init; }

    public bool Transferred { get; init; }

    /// <summary>5–300 when present.</summary>
    public int? IntervalSeconds { get; init; }

    public int? Rank { get; init; }

    /// <summary><c>error.code</c> when it is well-formed.</summary>
    public string? Code { get; init; }

    public string? Reason { get; init; }

    public string? Field { get; init; }

    public string? ErrorUsername { get; init; }

    public long? ServerTime { get; init; }

    public IReadOnlyList<int> Supported { get; init; } = [];

    /// <summary>From <c>Retry-After</c> (seconds or an HTTP date) or <c>error.retryAfterSeconds</c>, unclamped.</summary>
    public int? RetryAfterSeconds { get; init; }

    /// <summary><c>error.message</c> without control characters, at most 200 characters, for the log only.</summary>
    public string? LogMessage { get; init; }

    public bool IsSuccess => Status is >= 200 and <= 299;

    /// <summary>Parses a response; header names in any case. A body that is not the expected JSON leaves only the status.</summary>
    public static ReportReply Parse(int status, IReadOnlyDictionary<string, string> headers, ReadOnlySpan<byte> body, DateTimeOffset now)
    {
        int? retryAfter = null;
        foreach (var (name, value) in headers)
        {
            if (string.Equals(name, "retry-after", StringComparison.OrdinalIgnoreCase))
            {
                retryAfter = RetryAfter(value, now);
            }
        }

        var reply = new ReportReply(status) { RetryAfterSeconds = retryAfter };
        if (body.IsEmpty)
        {
            return reply;
        }

        try
        {
            using var document = JsonDocument.Parse(body.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return reply;
            }

            if (reply.IsSuccess)
            {
                return reply with
                {
                    Result = Text(root, "status") is { } result && SuccessStatuses.Contains(result) ? result : null,
                    DeviceId = Text(root, "deviceId") is { } id && ReportCanonical.IsDeviceId(id) ? id : null,
                    Username = BoundedName(Text(root, "username")),
                    ProfileUrl = ReportUrls.HttpsLink(Text(root, "profileUrl")),
                    Transferred = root.TryGetProperty("transferred", out var transferred) && transferred.ValueKind == JsonValueKind.True,
                    IntervalSeconds = Integer(root, "intervalSeconds") is { } seconds ? (int)Math.Clamp(seconds, 5, 300) : null,
                    Rank = Integer(root, "rank") is { } rank and >= 1 and <= 100_000_000 ? (int)rank : null,
                };
            }

            if (!root.TryGetProperty("error", out var error) || error.ValueKind != JsonValueKind.Object)
            {
                return reply;
            }

            return reply with
            {
                Code = Text(error, "code") is { } code && IsCode(code) ? code : null,
                Reason = Text(error, "reason") is { } reason ? Sanitized(reason, 32) : null,
                Field = Text(error, "field") is { } field ? Sanitized(field, 200) : null,
                ErrorUsername = BoundedName(Text(error, "username")),
                ServerTime = Integer(error, "serverTime") is { } serverTime and >= 0 ? serverTime : null,
                Supported = error.TryGetProperty("supported", out var supported) && supported.ValueKind == JsonValueKind.Array
                    ? supported.EnumerateArray().Take(16).Select(IntegerOf).Where(v => v is not null)
                        .Select(v => (int)Math.Clamp(v!.Value, int.MinValue, int.MaxValue)).ToArray()
                    : [],
                LogMessage = Text(error, "message") is { } message ? Sanitized(message, 200) : null,
                RetryAfterSeconds = retryAfter
                    ?? (Integer(error, "retryAfterSeconds") is { } after and >= 0 ? (int)Math.Min(after, 86_400) : null),
            };
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return reply;
        }
    }

    /// <summary><c>^[a-z][a-z0-9_]{0,47}$</c>.</summary>
    public static bool IsCode(string text) =>
        text.Length is >= 1 and <= 48 && text[0] is >= 'a' and <= 'z' && text.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '_');

    /// <summary>Seconds, or an HTTP date relative to <paramref name="now"/>.</summary>
    public static int? RetryAfter(string value, DateTimeOffset now)
    {
        var text = value.Trim();
        if (text.Length > 0 && text.All(char.IsAsciiDigit))
        {
            return int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) ? seconds : int.MaxValue;
        }

        string[] formats = ["r", "dddd, dd-MMM-yy HH:mm:ss 'GMT'", "ddd MMM d HH:mm:ss yyyy", "ddd MMM  d HH:mm:ss yyyy"];
        if (DateTimeOffset.TryParseExact(text, formats, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date))
        {
            return (int)Math.Clamp(Math.Ceiling((date - now).TotalSeconds), 0, int.MaxValue);
        }

        return null;
    }

    public static string Sanitized(string text, int cap)
    {
        var builder = new StringBuilder(Math.Min(text.Length, cap));
        var count = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format)
            {
                continue;
            }

            builder.Append(rune.ToString());
            if (++count >= cap)
            {
                break;
            }
        }

        return builder.ToString();
    }

    private static string? BoundedName(string? text) => text is not null && text.EnumerateRunes().Count() is >= 1 and <= 32 ? text : null;

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static long? Integer(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) ? IntegerOf(value) : null;

    private static long? IntegerOf(JsonElement value) =>
        value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) ? number : null;
}

/// <summary>What needs the user (DESIGN 11, the red statuses).</summary>
public enum ReportProblem
{
    ApiKey,
    UsernameTaken,
    UsernameRejected,
    KeyMismatch,
    Rejected,
    Upgrade,
    Gone,
    Forbidden,
}

/// <summary>How the client reacts to a report's outcome (REPORTING 8.3, METRICS 11.5).</summary>
public abstract record ReportReaction
{
    private ReportReaction()
    {
    }

    public static ReportReaction None { get; } = new NoReaction();

    public sealed record NoReaction : ReportReaction;

    /// <summary><c>timestamp_out_of_window</c>: keep <c>serverTime − local time</c> as the session's correction (METRICS 11.6).</summary>
    public sealed record CorrectClock(long? ServerTime) : ReportReaction;

    /// <summary><c>unknown_device</c>: register again (at most once per hour).</summary>
    public sealed record ReRegister : ReportReaction;

    /// <summary><c>signature_invalid</c> without a pending key: re-check the registration.</summary>
    public sealed record RecheckRegistration : ReportReaction;

    /// <summary><c>signature_invalid</c> with a pending key: the scheduler attempts again at once, signed with it.</summary>
    public sealed record UsePendingKey : ReportReaction;

    /// <summary><c>username_mismatch</c>: rename to the user's chosen name once.</summary>
    public sealed record Rename(string? Registered) : ReportReaction;

    /// <summary><c>seq_conflict</c>: start a new run.</summary>
    public sealed record NewRun : ReportReaction;

    /// <summary><c>version_unsupported</c>, <c>payload_too_large</c>: fetch the discovery document again.</summary>
    public sealed record RefreshDiscovery(bool Upgrade) : ReportReaction;

    /// <summary>A rejection that stops reporting after three in a row (<c>bad_request</c>, <c>payload_invalid</c>, <c>not_found</c> …).</summary>
    public sealed record Strike(bool Misconfigured) : ReportReaction;

    /// <summary>Stop until the user acts.</summary>
    public sealed record NeedsUser(ReportProblem Problem) : ReportReaction;
}

public static class ReportOutcome
{
    /// <summary>The scheduler's outcome and the reaction for a report attempt (REPORTING 8.3); a null reply is a transport failure.</summary>
    public static (ReportAttemptOutcome Outcome, ReportReaction Reaction) Classify(ReportReply? reply, bool hasPendingKey)
    {
        if (reply is null)
        {
            return (new ReportAttemptOutcome.Transient(), ReportReaction.None);
        }

        if (reply.IsSuccess)
        {
            return (new ReportAttemptOutcome.Delivered(reply.IntervalSeconds), ReportReaction.None);
        }

        int? retryAfter = reply.RetryAfterSeconds is { } after ? Math.Clamp(after, 5, 3600) : null;
        if (reply.Status is >= 300 and <= 399)
        {
            return (new ReportAttemptOutcome.Transient(), ReportReaction.None);
        }

        if (reply.Status == 429 || reply.Code == "rate_limited")
        {
            return (new ReportAttemptOutcome.RateLimited(retryAfter ?? 60), ReportReaction.None);
        }

        if (reply.Status >= 500)
        {
            return reply.Status == 503 && retryAfter is { } seconds
                ? (new ReportAttemptOutcome.RateLimited(seconds), ReportReaction.None)
                : (new ReportAttemptOutcome.Transient(), ReportReaction.None);
        }

        ReportAttemptOutcome rejected = new ReportAttemptOutcome.Rejected();
        return (reply.Code ?? StatusCode(reply.Status)) switch
        {
            "timestamp_out_of_window" => (rejected, new ReportReaction.CorrectClock(reply.ServerTime)),
            "nonce_replayed" => (new ReportAttemptOutcome.Again(), ReportReaction.None),
            "signature_invalid" => hasPendingKey
                ? (new ReportAttemptOutcome.Again(), new ReportReaction.UsePendingKey())
                : (rejected, new ReportReaction.RecheckRegistration()),
            "api_key_required" or "api_key_invalid" => (rejected, new ReportReaction.NeedsUser(ReportProblem.ApiKey)),
            "forbidden" => (rejected, new ReportReaction.NeedsUser(ReportProblem.Forbidden)),
            "unknown_device" => (rejected, new ReportReaction.ReRegister()),
            "not_found" or "method_not_allowed" => (rejected, new ReportReaction.Strike(Misconfigured: true)),
            "username_taken" => (rejected, new ReportReaction.NeedsUser(ReportProblem.UsernameTaken)),
            "username_mismatch" => (rejected, new ReportReaction.Rename(reply.ErrorUsername)),
            "device_conflict" => (rejected, new ReportReaction.NeedsUser(ReportProblem.KeyMismatch)),
            "seq_conflict" => (rejected, new ReportReaction.NewRun()),
            "gone" => (rejected, new ReportReaction.NeedsUser(ReportProblem.Gone)),
            "version_unsupported" => (rejected, new ReportReaction.RefreshDiscovery(Upgrade: true)),
            "payload_too_large" => (rejected, new ReportReaction.RefreshDiscovery(Upgrade: false)),
            "report_stale" or "length_required" => (rejected, ReportReaction.None),
            _ => (rejected, new ReportReaction.Strike(Misconfigured: false)),
        };
    }

    /// <summary>The code a response without a usable error body stands for (REPORTING 8.3, last paragraph).</summary>
    public static string StatusCode(int status) => status switch
    {
        404 or 405 => "not_found",
        410 => "gone",
        413 => "payload_too_large",
        403 => "forbidden",
        _ => "bad_request",
    };
}
