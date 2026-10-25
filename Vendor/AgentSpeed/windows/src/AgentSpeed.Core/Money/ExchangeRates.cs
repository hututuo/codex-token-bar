using System.Globalization;
using System.Text.Json;
using AgentSpeed.Core.Pricing;

namespace AgentSpeed.Core.Money;

/// <summary>Units per 1 USD of the supported currencies (USD = 1), as accepted from a provider (NETWORK 4).</summary>
/// <param name="Provider">
/// The provider's host (<c>open.er-api.com</c>, <c>cdn.jsdelivr.net</c>, <c>latest.currency-api.pages.dev</c>,
/// <c>api.frankfurter.dev</c>), shown in the status line.
/// </param>
/// <param name="DateMs">The rates' own date (Unix ms; provider 1: its update time, others: the date at 00:00 UTC).</param>
/// <param name="FetchedMs">When the rates were accepted (or last confirmed by a <c>304</c>).</param>
public sealed record ExchangeRateSet(string Provider, string Url, long DateMs, long FetchedMs, IReadOnlyDictionary<string, decimal> Rates)
{
    /// <summary>ExchangeRate-API's terms require the attribution link while its rates are in use (NETWORK 4).</summary>
    public bool NeedsAttribution => Provider == ExchangeRates.ErApiHost;

    public bool Equals(ExchangeRateSet? other) =>
        other is not null && Provider == other.Provider && Url == other.Url && DateMs == other.DateMs
        && FetchedMs == other.FetchedMs && ExchangeRates.SameRates(Rates, other.Rates);

    public override int GetHashCode() => HashCode.Combine(Provider, Url, DateMs, FetchedMs, Rates.Count);
}

/// <summary>
/// Response parsing and acceptance checks of NETWORK 4, exactly like <c>parse_rates</c> and <c>accept_rates</c> of
/// <c>spec/tools/prices.py</c>.
/// </summary>
public static class ExchangeRates
{
    public const string ErApiHost = "open.er-api.com";
    public const long DayMs = 86_400_000;
    public const long StaleReferenceMs = 30 * DayMs;
    public const long MaxFutureMs = 2 * DayMs;

    /// <summary>The three response shapes of NETWORK 4.</summary>
    public enum Shape
    {
        /// <summary>ExchangeRate-API open access (provider 1).</summary>
        ErApi,

        /// <summary>fawazahmed0 currency API (2a jsDelivr and 2b its Cloudflare Pages mirror).</summary>
        Fawaz,

        /// <summary>Frankfurter, the ECB reference rates (provider 3).</summary>
        Frankfurter,
    }

    public enum VerdictKind
    {
        Accepted,

        /// <summary>Check 4 has no usable reference (the last rates are older than 30 days): a second provider must agree.</summary>
        NeedsSecondProvider,
        Rejected,
    }

    /// <summary>The provider id of <c>spec/fixtures/rates-cases.json</c>.</summary>
    public static string IdOf(Shape shape) => shape switch
    {
        Shape.ErApi => ErApiHost,
        Shape.Fawaz => "currency-api",
        _ => "frankfurter",
    };

    public static Shape? ShapeOf(string id) => id switch
    {
        ErApiHost => Shape.ErApi,
        "currency-api" => Shape.Fawaz,
        "frankfurter" => Shape.Frankfurter,
        _ => null,
    };

    /// <summary>The rates' date (Unix ms) and the supported currencies' rates (codes upper-cased, USD = 1).</summary>
    /// <exception cref="FormatException">Not JSON, or not the provider's shape (the message is a short reason).</exception>
    public static ParsedRates Parse(Shape shape, ReadOnlySpan<byte> utf8, IReadOnlySet<string> supported)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            return Parse(shape, document.RootElement, supported);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            throw new FormatException("not JSON");
        }
    }

    /// <inheritdoc cref="Parse(Shape, ReadOnlySpan{byte}, IReadOnlySet{string})"/>
    public static ParsedRates Parse(Shape shape, JsonElement body, IReadOnlySet<string> supported)
    {
        ArgumentNullException.ThrowIfNull(supported);
        var root = RateJson.Members(body) ?? throw new FormatException("not an object");
        long dateMs;
        Dictionary<string, JsonElement> raw;
        switch (shape)
        {
            case Shape.ErApi:
                if (RateJson.String(root.GetValueOrDefault("result")) != "success"
                    || RateJson.String(root.GetValueOrDefault("base_code")) != "USD")
                {
                    throw new FormatException("not a successful USD response");
                }

                if (RateJson.Decimal(root.GetValueOrDefault("time_last_update_unix")) is not { } stamp || stamp <= 0 || stamp >= 1e15m)
                {
                    throw new FormatException("no update time");
                }

                dateMs = (long)decimal.Floor(stamp) * 1000;
                raw = RateJson.Members(root.GetValueOrDefault("rates")) ?? throw new FormatException("no rates");
                break;
            case Shape.Fawaz:
                if (DateMs(RateJson.String(root.GetValueOrDefault("date"))) is not { } fawazDate)
                {
                    throw new FormatException("no date");
                }

                dateMs = fawazDate;
                raw = RateJson.Members(root.GetValueOrDefault("usd")) ?? throw new FormatException("no rates");
                break;
            default:
                if (RateJson.String(root.GetValueOrDefault("base")) != "USD"
                    || DateMs(RateJson.String(root.GetValueOrDefault("date"))) is not { } frankfurterDate)
                {
                    throw new FormatException("not a USD response with a date");
                }

                dateMs = frankfurterDate;
                var rates = root.GetValueOrDefault("rates");
                raw = rates.ValueKind switch
                {
                    JsonValueKind.Undefined or JsonValueKind.Null => new Dictionary<string, JsonElement>(StringComparer.Ordinal),
                    JsonValueKind.Object => RateJson.Members(rates)!,
                    _ => throw new FormatException("no rates"),
                };
                raw.Remove("USD");
                break;
        }

        var result = new Dictionary<string, decimal>(StringComparer.Ordinal);
        foreach (var (code, value) in raw)
        {
            var upper = code.ToUpperInvariant();
            if (!supported.Contains(upper))
            {
                continue;
            }

            if (RateJson.Decimal(value) is not { } rate || rate <= 0)
            {
                throw new FormatException("bad rate for " + upper);
            }

            result[upper] = rate;
        }

        result[Currency.UsdCode] = 1;
        return new ParsedRates(dateMs, result);
    }

    /// <summary>Checks 3–5 for the selected currency.</summary>
    /// <param name="last">The last accepted rates; null before the first accepted fetch.</param>
    /// <param name="fallback">The bundled rates, the reference when <paramref name="last"/> is null.</param>
    /// <param name="other">A second provider's rates, for the cross-check when the reference is older than 30 days.</param>
    public static Verdict Check(
        long dateMs,
        IReadOnlyDictionary<string, decimal> rates,
        string selected,
        long nowMs,
        Reference? last,
        IReadOnlyDictionary<string, decimal>? fallback,
        IReadOnlyDictionary<string, decimal>? other = null)
    {
        ArgumentNullException.ThrowIfNull(rates);
        if (dateMs > nowMs + MaxFutureMs)
        {
            return Verdict.Rejected("date in the future");
        }

        if (last is not null && dateMs < last.DateMs)
        {
            return Verdict.Rejected("older than the stored rates");
        }

        if (!rates.TryGetValue(selected, out var value))
        {
            return Verdict.Rejected("selected currency missing");
        }

        decimal? reference = last is not null
            ? nowMs - last.AcceptedMs <= StaleReferenceMs && last.Rates.TryGetValue(selected, out var previous) ? previous : null
            : fallback is not null && fallback.TryGetValue(selected, out var bundled) ? bundled : null;
        if (reference is { } bound)
        {
            return bound / 2 <= value && value / 2 <= bound ? Verdict.Accepted : Verdict.Rejected("outside x0.5..x2");
        }

        if (other is null || !other.TryGetValue(selected, out var second))
        {
            return Verdict.NeedsSecondProvider;
        }

        return Math.Abs(value - second) <= second * 0.03m ? Verdict.Accepted : Verdict.Rejected("providers disagree");
    }

    internal static bool SameRates(IReadOnlyDictionary<string, decimal> lhs, IReadOnlyDictionary<string, decimal> rhs) =>
        lhs.Count == rhs.Count && lhs.All(pair => rhs.TryGetValue(pair.Key, out var value) && value == pair.Value);

    /// <summary>A <c>YYYY-MM-DD</c> date of ASCII digits at 00:00 UTC.</summary>
    private static long? DateMs(string? text) => UtcDay.IsDateText(text) ? UtcDay.InstantMs(text) : null;

    /// <summary>The last accepted rates for check 4: their date, when they were accepted and the rates.</summary>
    public sealed record Reference(long DateMs, long AcceptedMs, IReadOnlyDictionary<string, decimal> Rates);

    public readonly record struct Verdict(VerdictKind Kind, string? Reason = null)
    {
        public static Verdict Accepted => new(VerdictKind.Accepted);

        public static Verdict NeedsSecondProvider => new(VerdictKind.NeedsSecondProvider);

        public bool IsAccepted => Kind == VerdictKind.Accepted;

        public static Verdict Rejected(string reason) => new(VerdictKind.Rejected, reason);

        public override string ToString() => Reason is null ? Kind.ToString() : $"{Kind}: {Reason}";
    }
}

/// <summary>A provider response's date (Unix ms) and its supported rates.</summary>
public sealed record ParsedRates(long DateMs, IReadOnlyDictionary<string, decimal> Rates);

/// <summary>
/// JSON values as <c>spec/tools/prices.py</c> sees them: objects keep the last value of a repeated key, and numbers convert
/// to decimals the way Python's <c>Decimal</c> reads them (an integer literal exactly, any other literal as its nearest
/// double in the shortest text that reads back, never through a lossy cast).
/// </summary>
internal static class RateJson
{
    public static Dictionary<string, JsonElement>? Members(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var members = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            members[property.Name] = property.Value;
        }

        return members;
    }

    public static string? String(JsonElement element) => element.ValueKind == JsonValueKind.String ? element.GetString() : null;

    /// <summary>An integer literal (no fraction, no exponent) that fits in 64 bits.</summary>
    public static long? Int64(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number)
        {
            return null;
        }

        var text = element.GetRawText();
        return IsInteger(text) && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    /// <summary>A finite number within <see cref="decimal"/>'s range.</summary>
    public static decimal? Decimal(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number)
        {
            return null;
        }

        var text = element.GetRawText();
        if (IsInteger(text))
        {
            return decimal.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer) ? integer : null;
        }

        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var nearest) || !double.IsFinite(nearest))
        {
            return null;
        }

        return decimal.TryParse(nearest.ToString("R", CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    private static bool IsInteger(string literal) => literal.AsSpan().IndexOfAny('.', 'e', 'E') < 0;
}
