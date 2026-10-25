using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Pricing;

/// <summary>
/// One price set in integer micro-USD per million tokens (= pico-USD per token), with the defaults of METRICS 9.1
/// applied: a missing <c>cachedInput</c> or <c>cacheWrite</c> is <c>input</c>, a missing <c>cacheWrite1h</c> is <c>cacheWrite</c>.
/// </summary>
public readonly record struct PriceSet(long Input, long CachedInput, long CacheWrite, long CacheWrite1h, long Output);

/// <summary>A long-context tier: replaces the prices of a whole response whose <c>input</c> is above <see cref="Above"/>.</summary>
public readonly record struct PriceTier(long Above, PriceSet Prices);

/// <summary>Base prices with their optional tiers.</summary>
public sealed record TieredPrices(PriceSet Prices, IReadOnlyList<PriceTier> Tiers)
{
    /// <summary>The price set for a response of <paramref name="inputTokens"/>, and the tier used (null = the base prices).</summary>
    public (PriceSet Prices, int? Tier) Select(long inputTokens)
    {
        var chosen = Prices;
        int? index = null;
        for (var i = 0; i < Tiers.Count; i++)
        {
            if (inputTokens > Tiers[i].Above)
            {
                chosen = Tiers[i].Prices;
                index = i;
            }
        }

        return (chosen, index);
    }
}

/// <summary>DeepSeek-style off-peak pricing (METRICS 9.1): peak only inside a UTC window of a peak weekday that is not an off-peak date.</summary>
/// <param name="PeakWindows"><c>[start, end)</c> in minutes of the UTC day.</param>
public sealed record OffPeakRule(
    IReadOnlyList<(int Start, int End)> PeakWindows,
    IReadOnlySet<int> PeakWeekdays,
    IReadOnlySet<string> OffPeakDates,
    TieredPrices Pricing)
{
    public bool IsOffPeak(long ms)
    {
        var day = new UtcDay(ms);
        if (OffPeakDates.Contains(day.Label) || !PeakWeekdays.Contains(day.IsoWeekday))
        {
            return true;
        }

        var minute = day.MinuteOfDay;
        foreach (var (start, end) in PeakWindows)
        {
            if (start <= minute && minute < end)
            {
                return false;
            }
        }

        return true;
    }
}

/// <summary>Prices of a model, or of one of its periods.</summary>
public sealed record ModelPricing(TieredPrices Base, OffPeakRule? OffPeak);

/// <summary>Prices that apply while <c>fromMs ≤ endMs &lt; toMs</c> (METRICS 9.1 periods).</summary>
public sealed record PricePeriod(long? FromMs, long? ToMs, ModelPricing Pricing)
{
    public bool Covers(long ms) => (FromMs is not { } from || from <= ms) && (ToMs is not { } to || ms < to);
}

/// <param name="Pricing">Null exactly when the model is free.</param>
public sealed record PriceModel(
    string Id,
    string Provider,
    string Name,
    string Status,
    bool IsFree,
    ModelPricing? Pricing,
    IReadOnlyList<PricePeriod> Periods,
    TieredPrices? Fast,
    IReadOnlyList<string> Aliases,
    string Source,
    string Checked,
    string? Note)
{
    /// <summary>
    /// The prices for one response (METRICS 9.1, 9.3): fast prices for a fast response, else the period covering
    /// <paramref name="endMs"/>, then its off-peak prices when it is off-peak. Null when a fast response has no fast price.
    /// </summary>
    public TieredPrices? PricingFor(long? endMs, bool fast)
    {
        if (fast)
        {
            return Fast;
        }

        if (Pricing is not { } applied)
        {
            return null;
        }

        if (endMs is { } at)
        {
            foreach (var period in Periods)
            {
                if (period.Covers(at))
                {
                    applied = period.Pricing;
                    break;
                }
            }

            if (applied.OffPeak is { } rule && rule.IsOffPeak(at))
            {
                return rule.Pricing;
            }
        }

        return applied.Base;
    }
}

public sealed record PriceProvider(string Name, string Url);

/// <summary>The lists that drive model resolution (METRICS 9.2).</summary>
public sealed record PriceNormalization(
    IReadOnlyList<string> FreeProviders,
    IReadOnlyList<string> CloudSuffixes,
    IReadOnlyList<string> BedrockRegions,
    IReadOnlyList<string> BedrockVendors,
    IReadOnlyList<string> FreeSuffixes,
    IReadOnlyList<string> VariantSuffixes,
    IReadOnlyList<string> FastSuffixes,
    IReadOnlyList<(string Prefix, string To)> Rewrites,
    IReadOnlyList<string> DateSuffixPrefixes,
    IReadOnlyList<(string Prefix, IReadOnlyList<string> Suffixes)> ModifierSuffixes,
    IReadOnlyList<string> DotHyphenPrefixes);

/// <summary>An id known to have no public price.</summary>
public sealed record UnknownModelRule(bool IsPrefix, string Value, string Reason);

/// <summary>A row of the table's own <c>tests</c> (METRICS 9.1).</summary>
public sealed record PriceTableTest(string? Model, string? Provider, string Expect);

public enum PriceTableErrorKind
{
    TooLarge,
    NotJson,

    /// <summary>A table of another schema (NETWORK 3: a higher one needs a newer build).</summary>
    UnsupportedSchema,

    /// <summary>The rules of <c>validate_table</c> in <c>spec/tools/prices.py</c>, or the table's own <c>tests</c>.</summary>
    Invalid,
}

public sealed record PriceTableError(PriceTableErrorKind Kind, int? Schema, IReadOnlyList<string> Errors)
{
    public bool IsNewerSchema => Kind == PriceTableErrorKind.UnsupportedSchema && Schema > PriceTable.SupportedSchema;

    public override string ToString() => Kind switch
    {
        PriceTableErrorKind.TooLarge => "too large",
        PriceTableErrorKind.NotJson => "not a JSON object",
        PriceTableErrorKind.UnsupportedSchema => "schema " + (Schema?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "missing"),
        _ => $"{Errors.Count} validation errors, first: {(Errors.Count > 0 ? Errors[0] : string.Empty)}",
    };
}

public readonly record struct PriceTableLoadResult(PriceTable? Table, PriceTableError? Error);

/// <summary>A validated price table (METRICS 9.1). Build one with <see cref="Load"/>.</summary>
public sealed class PriceTable
{
    public const int SupportedSchema = 1;

    /// <summary>Downloads and stored copies above this size are rejected (NETWORK 3).</summary>
    public const int MaxBytes = 1 << 20;

    internal PriceTable(
        int version,
        string updated,
        IReadOnlyDictionary<string, PriceProvider> providers,
        PriceNormalization normalize,
        IReadOnlyList<PriceModel> models,
        IReadOnlyList<UnknownModelRule> unknown,
        IReadOnlyList<PriceTableTest> tests,
        byte[] data)
    {
        Version = version;
        Updated = updated;
        Providers = providers;
        Normalize = normalize;
        Models = models;
        Unknown = unknown;
        Tests = tests;
        Data = data;
        Resolver = new ModelResolver(normalize, models, unknown);
    }

    public int Version { get; }

    public string Updated { get; }

    public IReadOnlyDictionary<string, PriceProvider> Providers { get; }

    public PriceNormalization Normalize { get; }

    public IReadOnlyList<PriceModel> Models { get; }

    public IReadOnlyList<UnknownModelRule> Unknown { get; }

    public IReadOnlyList<PriceTableTest> Tests { get; }

    /// <summary>The document as loaded, for the history store's copies (METRICS 9.7) and the synced file.</summary>
    public byte[] Data { get; }

    public ModelResolver Resolver { get; }

    /// <summary>Parses and validates a table exactly like <c>spec/tools/prices.py</c> (NETWORK 3 checks 1–4).</summary>
    public static PriceTableLoadResult Load(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length > MaxBytes)
        {
            return new(null, new PriceTableError(PriceTableErrorKind.TooLarge, null, []));
        }

        if (PriceJson.Parse(utf8) is not { IsObject: true } document)
        {
            return new(null, new PriceTableError(PriceTableErrorKind.NotJson, null, []));
        }

        var schema = document["schema"]?.Int64;
        if (schema != SupportedSchema)
        {
            int? reported = schema is { } s && s is >= int.MinValue and <= int.MaxValue ? (int)s : null;
            return new(null, new PriceTableError(PriceTableErrorKind.UnsupportedSchema, reported, []));
        }

        var validator = new PriceTableValidator();
        var table = validator.Validate(document, utf8.ToArray());
        return table is null
            ? new(null, new PriceTableError(PriceTableErrorKind.Invalid, SupportedSchema, validator.Errors))
            : new(table, null);
    }

    /// <summary>Integer micro-USD of one response, or null when its price is unknown (METRICS 9.3). Free models cost 0.</summary>
    internal long? Cost(string? model, string? provider, in TokenCounts tokens, long? endMs, bool fast)
    {
        var resolution = Resolver.Resolve(model, provider);
        switch (resolution.Kind)
        {
            case ResolutionKind.Free:
                return 0;
            case ResolutionKind.Unknown:
                return null;
        }

        var pricing = Models[resolution.Index].PricingFor(endMs, resolution.Fast || fast);
        return pricing is null ? null : ResponseCost.MicroUsd(ResponseCost.PicoUsd(tokens, pricing).Pico);
    }

    internal long? Cost(ParsedResponse response) =>
        Cost(response.Model, response.Provider, response.Tokens, response.EndMs, response.Fast);

    /// <summary>
    /// The id a response's model is reported as (METRICS 11.3): a hit on a table entry (priced or free) is that entry's id, a
    /// local runtime (<c>freeProviders</c>) is <c>local</c>, everything else is <c>unknown</c>. Raw names never leave the app.
    /// </summary>
    public string ReportModelId(string? model, string? provider)
    {
        var resolution = Resolver.Resolve(model, provider);
        string? id = resolution.Kind switch
        {
            ResolutionKind.Priced => Models[resolution.Index].Id,
            ResolutionKind.Free when resolution.Index >= 0 => Models[resolution.Index].Id,
            ResolutionKind.Free when Resolver.IsLocalProvider(model, provider) => Reporting.ReportModelIds.Local,
            _ => null,
        };
        return id is not null && Reporting.ReportModelIds.IsValid(id) ? id : Reporting.ReportModelIds.Unknown;
    }

    /// <summary><c>Resolution.label</c> of <c>prices.py</c>: the model id (with <c> fast</c>), <c>free</c> or <c>unknown</c>.</summary>
    public string Label(ModelResolution resolution) => resolution.Kind switch
    {
        ResolutionKind.Priced => Models[resolution.Index].Id + (resolution.Fast ? " fast" : string.Empty),
        ResolutionKind.Free => "free",
        _ => "unknown",
    };
}
