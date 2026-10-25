using System.Numerics;

namespace AgentSpeed.Core.Pricing;

/// <summary><c>validate_table</c> of <c>spec/tools/prices.py</c>, rule for rule, on the raw document.</summary>
internal sealed class PriceTableValidator
{
    private static readonly string[] PriceFields = ["input", "cachedInput", "cacheWrite", "cacheWrite1h", "output"];
    private static readonly string[] RequiredPrices = ["input", "output"];
    private static readonly HashSet<string> Statuses = ["current", "preview", "legacy", "deprecated", "retired"];

    private static readonly string[] NormalizeLists =
    [
        "freeProviders", "cloudSuffixes", "bedrockRegions", "bedrockVendors", "freeSuffixes", "variantSuffixes",
        "fastSuffixes", "dateSuffixPrefixes", "dotHyphenPrefixes",
    ];

    private static readonly HashSet<string> NormalizeKeys = [.. NormalizeLists, "rewrites", "modifierSuffixes"];

    private static readonly HashSet<string> ModelKeys =
    [
        "id", "provider", "name", "status", "free", "prices", "tiers", "offPeak", "periods", "fast", "aliases", "source",
        "checked", "note",
    ];

    private static readonly HashSet<string> FreeModelKeys = ["id", "provider", "name", "status", "free", "aliases", "source", "checked", "note"];
    private static readonly HashSet<string> FastKeys = ["prices", "tiers"];
    private static readonly HashSet<string> PeriodKeys = ["from", "to", "prices", "tiers", "offPeak", "note"];
    private static readonly HashSet<string> OffPeakKeys = ["peakUtc", "peakWeekdays", "offPeakDates", "prices", "tiers"];
    private const int MaxModels = 2000;
    private static readonly BigInteger MaxPriceMicro = new(10_000L * 1_000_000);

    public List<string> Errors { get; } = [];

    public PriceTable? Validate(PriceJson t, byte[] data)
    {
        if (!t.IsObject)
        {
            Errors.Add("table is not an object");
            return null;
        }

        if (t["schema"]?.Int64 != PriceTable.SupportedSchema)
        {
            Errors.Add("schema must be 1");
        }

        var version = t["version"]?.Int64;
        if (version is not >= 1)
        {
            Errors.Add("version must be a positive integer");
        }

        var updated = t["updated"]?.String;
        if (!UtcDay.IsDateText(updated))
        {
            Errors.Add("updated must be YYYY-MM-DD");
        }

        if (t["currency"]?.String != "USD" || t["unit"]?.String != "perMillionTokens")
        {
            Errors.Add("currency must be \"USD\" and unit \"perMillionTokens\"");
        }

        var providers = new Dictionary<string, PriceProvider>(StringComparer.Ordinal);
        if (t["providers"] is { IsObject: true } rawProviders && rawProviders.Members.Count > 0)
        {
            foreach (var key in rawProviders.Keys)
            {
                var entry = rawProviders.Members[key];
                var name = entry["name"];
                var url = PriceJson.PythonString(entry["url"]);
                if (!IsId(key) || !entry.IsObject || !PriceJson.Truthy(name) || !url.StartsWith("https://", StringComparison.Ordinal))
                {
                    Errors.Add($"provider {key}: needs name and an https url");
                }

                providers[key] = new PriceProvider(name?.String ?? string.Empty, url);
            }
        }
        else
        {
            Errors.Add("providers must be a non-empty object");
        }

        if (t["normalize"] is not { IsObject: true } norm || !NormalizeKeys.SetEquals(norm.Members.Keys))
        {
            Errors.Add("normalize must have exactly [" + string.Join(", ", NormalizeKeys.Order(StringComparer.Ordinal).Select(k => "'" + k + "'")) + "]");
            return null;
        }

        var normalize = ValidateNormalize(norm);
        if (normalize is null || Errors.Count > 0)
        {
            return null;
        }

        if (t["models"] is not { IsArray: true } rawModels || rawModels.Items.Count == 0 || rawModels.Items.Count > MaxModels)
        {
            Errors.Add($"models must be a list of 1..{MaxModels} entries");
            return null;
        }

        var models = new List<PriceModel>();
        var keyCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var keyOrder = new List<string>();
        for (var index = 0; index < rawModels.Items.Count; index++)
        {
            var raw = rawModels.Items[index];
            if (ValidateModel(raw, index, providers, updated) is { } model)
            {
                models.Add(model);
            }

            if (!raw.IsObject)
            {
                continue;
            }

            var keys = Aliases(raw["aliases"]) ?? [];
            if (raw["id"]?.String is { } id)
            {
                keys.Insert(0, id);
            }

            foreach (var key in keys)
            {
                if (!keyCounts.TryGetValue(key, out var count))
                {
                    keyOrder.Add(key);
                }

                keyCounts[key] = count + 1;
            }
        }

        foreach (var key in keyOrder)
        {
            if (keyCounts[key] > 1)
            {
                Errors.Add($"id or alias \"{key}\" is used {keyCounts[key]} times");
            }
        }

        var unknown = new List<UnknownModelRule>();
        if (t["unknown"] is { } rawUnknown)
        {
            if (rawUnknown.IsArray)
            {
                for (var index = 0; index < rawUnknown.Items.Count; index++)
                {
                    var entry = rawUnknown.Items[index];
                    var match = entry["match"]?.String;
                    var value = entry["value"]?.String;
                    if (match is not ("exact" or "prefix") || string.IsNullOrEmpty(value) || !ModelResolver.IsTrimmedLowercase(value)
                        || !PriceJson.Truthy(entry["reason"]))
                    {
                        Errors.Add($"unknown[{index}]: needs match exact|prefix, a lowercase value and a reason");
                        continue;
                    }

                    var isPrefix = match == "prefix";
                    foreach (var key in keyOrder)
                    {
                        if (isPrefix ? key.StartsWith(value, StringComparison.Ordinal) : key == value)
                        {
                            Errors.Add($"unknown[{index}] \"{value}\" shadows the id or alias \"{key}\"");
                        }
                    }

                    unknown.Add(new UnknownModelRule(isPrefix, value, PriceJson.PythonString(entry["reason"])));
                }
            }
            else
            {
                Errors.Add("unknown must be a list");
            }
        }

        if (Errors.Count > 0 || version is not { } tableVersion || version > int.MaxValue || updated is null)
        {
            if (Errors.Count == 0)
            {
                Errors.Add("version must be a positive integer");
            }

            return null;
        }

        var tests = new List<PriceTableTest>();
        var testIndices = new List<int>();
        if (t["tests"] is { } rawTests)
        {
            if (rawTests.IsArray)
            {
                for (var index = 0; index < rawTests.Items.Count; index++)
                {
                    var entry = rawTests.Items[index];
                    if (!entry.IsObject || entry["expect"]?.String is not { } expect || entry["model"] is null)
                    {
                        Errors.Add($"tests[{index}]: needs model and expect");
                        continue;
                    }

                    tests.Add(new PriceTableTest(entry["model"]!.String, entry["provider"]?.String, expect));
                    testIndices.Add(index);
                }
            }
            else
            {
                Errors.Add("tests must be a list");
            }
        }

        var table = new PriceTable((int)tableVersion, updated, providers, normalize, models, unknown, tests, data);
        for (var index = 0; index < models.Count; index++)
        {
            var model = models[index];
            foreach (var key in model.Aliases.Prepend(model.Id))
            {
                var resolution = table.Resolver.Resolve(key, null);
                var ok = resolution.Index == index && !resolution.Fast
                    && resolution.Kind == (model.IsFree ? ResolutionKind.Free : ResolutionKind.Priced);
                if (!ok)
                {
                    Errors.Add($"\"{key}\" does not resolve to {model.Id} (got {table.Label(resolution)})");
                }
            }
        }

        for (var i = 0; i < tests.Count; i++)
        {
            var test = tests[i];
            var got = table.Label(table.Resolver.Resolve(test.Model, test.Provider));
            if (got != test.Expect)
            {
                Errors.Add($"tests[{testIndices[i]}]: {test.Model ?? "null"} (provider {test.Provider ?? "None"}) expected {test.Expect} got {got}");
            }
        }

        return Errors.Count == 0 ? table : null;
    }

    private PriceNormalization? ValidateNormalize(PriceJson norm)
    {
        var lists = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var key in NormalizeLists)
        {
            if (LowercaseList(norm[key]) is { } list)
            {
                lists[key] = list;
            }
            else
            {
                Errors.Add($"normalize.{key} must be unique lowercase strings");
            }
        }

        var rewrites = new List<(string, string)>();
        if (norm["rewrites"] is { IsArray: true } rawRewrites && rawRewrites.Items.All(entry =>
                entry.IsObject && entry.Members.Count == 2 && entry["prefix"] is { } prefix && entry["to"] is { } to
                && LowercaseList([prefix, to]) is not null))
        {
            rewrites.AddRange(rawRewrites.Items.Select(e => (e["prefix"]!.String!, e["to"]!.String!)));
        }
        else
        {
            Errors.Add("normalize.rewrites must be {prefix, to} objects with lowercase strings");
        }

        var modifiers = new List<(string, IReadOnlyList<string>)>();
        if (norm["modifierSuffixes"] is { IsArray: true } rawModifiers && rawModifiers.Items.All(entry =>
                entry.IsObject && entry.Members.Count == 2 && entry["prefix"] is { } prefix && entry["suffixes"] is { } suffixes
                && LowercaseList([prefix]) is not null && LowercaseList(suffixes) is not null))
        {
            modifiers.AddRange(rawModifiers.Items.Select(e => (e["prefix"]!.String!, (IReadOnlyList<string>)LowercaseList(e["suffixes"])!)));
        }
        else
        {
            Errors.Add("normalize.modifierSuffixes must be {prefix, suffixes} objects with lowercase strings");
        }

        if (Errors.Count > 0)
        {
            return null;
        }

        return new PriceNormalization(
            lists["freeProviders"], lists["cloudSuffixes"], lists["bedrockRegions"], lists["bedrockVendors"],
            lists["freeSuffixes"], lists["variantSuffixes"], lists["fastSuffixes"], rewrites,
            lists["dateSuffixPrefixes"], modifiers, lists["dotHyphenPrefixes"]);
    }

    private PriceModel? ValidateModel(PriceJson raw, int index, Dictionary<string, PriceProvider> providers, string? updated)
    {
        var start = Errors.Count;
        var where = $"models[{index}] {(raw.IsObject ? PriceJson.PythonString(raw["id"]) : "?")}";
        if (!raw.IsObject)
        {
            Errors.Add(where + ": not an object");
            return null;
        }

        var id = raw["id"]?.String;
        if (id is null || !IsId(id))
        {
            Errors.Add(where + ": id must be lowercase [a-z0-9._:+-]");
        }

        var provider = raw["provider"]?.String;
        if (provider is null || !providers.ContainsKey(provider))
        {
            Errors.Add($"{where}: provider {PythonRepr(raw["provider"])} is not in providers");
        }

        var name = raw["name"]?.String;
        if (name is null || ModelResolver.Strip(name).Length == 0)
        {
            Errors.Add(where + ": name is required");
        }

        var status = raw["status"]?.String;
        if (status is null || !Statuses.Contains(status))
        {
            Errors.Add(where + ": status must be one of ['current', 'deprecated', 'legacy', 'preview', 'retired']");
        }

        var source = PriceJson.PythonString(raw["source"]);
        if (raw["source"] is null || !source.StartsWith("https://", StringComparison.Ordinal))
        {
            Errors.Add(where + ": source must be an https URL");
        }

        var checkedDate = raw["checked"]?.String;
        if (!UtcDay.IsDateText(checkedDate) || (updated is not null && string.CompareOrdinal(checkedDate, updated) > 0))
        {
            Errors.Add(where + ": checked must be YYYY-MM-DD, not after updated");
        }

        if (raw["note"] is { } note && note.String is null)
        {
            Errors.Add(where + ": note must be a string");
        }

        ModelPricing? pricing = null;
        IReadOnlyList<PricePeriod> periods = [];
        TieredPrices? fast = null;
        var isFree = raw["free"] is { Kind: PriceJsonKind.Bool, BoolValue: true };
        if (isFree)
        {
            var extra = raw.Members.Keys.Where(k => !FreeModelKeys.Contains(k)).Order(StringComparer.Ordinal).ToList();
            if (extra.Count > 0)
            {
                Errors.Add($"{where}: a free model has no {string.Join(", ", extra)}");
            }
        }
        else if (raw["free"] is not null)
        {
            Errors.Add(where + ": free must be true or absent");
        }
        else
        {
            pricing = CheckPricing(raw, where, ModelKeys, allowsOffPeak: true);
            if (raw["fast"] is { } rawFast)
            {
                fast = CheckPricing(rawFast, where + ".fast", FastKeys, allowsOffPeak: false)?.Base;
            }

            periods = CheckPeriods(raw["periods"], where);
        }

        IReadOnlyList<string> aliases = [];
        if (raw["aliases"] is { } rawAliases)
        {
            if (Aliases(rawAliases) is { } valid)
            {
                aliases = valid;
            }
            else
            {
                Errors.Add(where + ": aliases must be trimmed lowercase strings");
            }
        }

        if (Errors.Count != start || id is null || provider is null || name is null || status is null || checkedDate is null)
        {
            return null;
        }

        return new PriceModel(id, provider, name, status, isFree, pricing, periods, fast, aliases, source, checkedDate, raw["note"]?.String);
    }

    private List<PricePeriod> CheckPeriods(PriceJson? raw, string where)
    {
        var periods = new List<PricePeriod>();
        if (raw is null)
        {
            return periods;
        }

        if (!raw.IsArray)
        {
            Errors.Add(where + ": periods must be a list");
            return periods;
        }

        var spans = new List<(long Lo, long Hi)>();
        for (var index = 0; index < raw.Items.Count; index++)
        {
            var pw = $"{where}.periods[{index}]";
            var entry = raw.Items[index];
            if (!entry.IsObject || (entry["from"] is null && entry["to"] is null)
                || (entry["from"] is { } f && UtcDay.InstantMs(f.String) is null)
                || (entry["to"] is { } t && UtcDay.InstantMs(t.String) is null))
            {
                Errors.Add(pw + ": needs from and/or to (YYYY-MM-DD or YYYY-MM-DDTHH:MMZ, UTC)");
                continue;
            }

            var from = UtcDay.InstantMs(entry["from"]?.String);
            var to = UtcDay.InstantMs(entry["to"]?.String);
            var lo = from ?? long.MinValue;
            var hi = to ?? long.MaxValue;
            if (lo >= hi)
            {
                Errors.Add(pw + ": from must be before to");
            }

            if (spans.Any(s => lo < s.Hi && s.Lo < hi))
            {
                Errors.Add(pw + ": overlaps another period");
            }

            spans.Add((lo, hi));
            if (CheckPricing(entry, pw, PeriodKeys, allowsOffPeak: true) is { } pricing)
            {
                periods.Add(new PricePeriod(from, to, pricing));
            }
        }

        return periods;
    }

    /// <summary><c>prices</c> plus optional ascending <c>tiers</c> with the same fields, and optionally <c>offPeak</c> (METRICS 9.1).</summary>
    private ModelPricing? CheckPricing(PriceJson raw, string where, HashSet<string> allowed, bool allowsOffPeak)
    {
        var start = Errors.Count;
        if (!raw.IsObject)
        {
            Errors.Add(where + ": not an object");
            return null;
        }

        foreach (var key in raw.Keys)
        {
            if (!allowed.Contains(key))
            {
                Errors.Add($"{where}: unknown field {key}");
            }
        }

        var basePrices = CheckPriceSet(raw["prices"], where + ".prices");
        var baseObject = raw["prices"] is { IsObject: true } p ? p : null;
        var fields = SetFields(baseObject);
        if (baseObject?["above"] is not null)
        {
            Errors.Add(where + ".prices: above belongs in tiers");
        }

        long last = 0;
        var tiers = new List<PriceTier>();
        IReadOnlyList<PriceJson> rawTiers = [];
        if (raw["tiers"] is { } tiersValue)
        {
            if (tiersValue.IsArray)
            {
                rawTiers = tiersValue.Items;
            }
            else
            {
                Errors.Add(where + ": tiers must be a list");
            }
        }

        for (var index = 0; index < rawTiers.Count; index++)
        {
            var tw = $"{where}.tiers[{index}]";
            var tier = rawTiers[index];
            var prices = CheckPriceSet(tier, tw);
            if (!tier.IsObject)
            {
                continue;
            }

            if (tier["above"]?.Int64 is { } above && above > last)
            {
                last = above;
                if (prices is { } set)
                {
                    tiers.Add(new PriceTier(above, set));
                }
            }
            else
            {
                Errors.Add(tw + ": above must be an integer greater than the previous threshold");
            }

            if (!SetFields(tier).SetEquals(fields))
            {
                Errors.Add($"{tw}: must set exactly the price fields of the base prices [{string.Join(", ", fields.Order(StringComparer.Ordinal).Select(f => "'" + f + "'"))}]");
            }
        }

        OffPeakRule? rule = null;
        if (raw["offPeak"] is { } rawRule)
        {
            if (!allowsOffPeak)
            {
                Errors.Add(where + ": offPeak is not allowed here");
                return null;
            }

            rule = CheckOffPeak(rawRule, where + ".offPeak");
        }

        if (Errors.Count != start || basePrices is not { } prices0)
        {
            return null;
        }

        return new ModelPricing(new TieredPrices(prices0, tiers), rule);
    }

    private OffPeakRule? CheckOffPeak(PriceJson raw, string ow)
    {
        var start = Errors.Count;
        var pricing = CheckPricing(raw, ow, OffPeakKeys, allowsOffPeak: false);
        if (!raw.IsObject)
        {
            return null;
        }

        var windows = new List<(int, int)>();
        if (raw["peakUtc"] is { IsArray: true } list && list.Items.Count > 0 && list.Items.All(w => Window(w.String) is not null))
        {
            windows.AddRange(list.Items.Select(w => Window(w.String)!.Value));
        }
        else
        {
            Errors.Add(ow + ".peakUtc: windows HH:MM-HH:MM with start < end <= 24:00");
        }

        var weekdays = new HashSet<int>();
        if (raw["peakWeekdays"] is { IsArray: true } days && days.Items.Count > 0 && days.Items.All(d => Weekday(d) is not null))
        {
            weekdays.UnionWith(days.Items.Select(d => Weekday(d)!.Value));
        }
        else
        {
            Errors.Add(ow + ".peakWeekdays: ISO weekdays 1 (Monday) .. 7");
        }

        var dates = new HashSet<string>(StringComparer.Ordinal);
        if (raw["offPeakDates"] is { } rawDates)
        {
            if (rawDates.IsArray && rawDates.Items.All(d => UtcDay.IsDateText(d.String)))
            {
                dates.UnionWith(rawDates.Items.Select(d => d.String!));
            }
            else
            {
                Errors.Add(ow + ".offPeakDates: YYYY-MM-DD dates");
            }
        }

        if (Errors.Count != start || pricing is null)
        {
            return null;
        }

        return new OffPeakRule(windows, weekdays, dates, pricing.Base);
    }

    private PriceSet? CheckPriceSet(PriceJson? raw, string where)
    {
        var start = Errors.Count;
        if (raw is not { IsObject: true })
        {
            Errors.Add(where + ": not an object");
            return null;
        }

        foreach (var key in raw.Keys)
        {
            if (Array.IndexOf(PriceFields, key) < 0 && key != "above")
            {
                Errors.Add($"{where}: unknown field {key}");
            }
        }

        foreach (var key in RequiredPrices)
        {
            if (raw[key] is null or { IsNull: true })
            {
                Errors.Add($"{where}: {key} is required");
            }
        }

        var micro = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var key in PriceFields)
        {
            if (raw[key] is { IsNull: false } value && CheckPrice(value, $"{where}.{key}") is { } price)
            {
                micro[key] = price;
            }
        }

        if (Errors.Count != start || !micro.TryGetValue("input", out var input) || !micro.TryGetValue("output", out var output))
        {
            return null;
        }

        var cacheWrite = micro.GetValueOrDefault("cacheWrite", input);
        return new PriceSet(input, micro.GetValueOrDefault("cachedInput", input), cacheWrite, micro.GetValueOrDefault("cacheWrite1h", cacheWrite), output);
    }

    /// <summary>A price 0–10 000 USD per million tokens with at most 6 decimals, as integer micro-USD per million tokens.</summary>
    private long? CheckPrice(PriceJson value, string where)
    {
        if (value.Kind != PriceJsonKind.Number)
        {
            Errors.Add(where + ": not a number");
            return null;
        }

        if (Micro(value) is not { } scaled)
        {
            Errors.Add($"{where}: {value.Text} out of range 0..10000");
            return null;
        }

        if (scaled.Fraction)
        {
            Errors.Add($"{where}: price {value.Text} has more than 6 decimals");
            return null;
        }

        return scaled.Value;
    }

    /// <summary><c>price × 1 000 000</c>, or null when out of range; <c>Fraction</c> when it is not an integer.</summary>
    internal static (long Value, bool Fraction)? Micro(PriceJson value)
    {
        if (value.Exact is not { } exact)
        {
            return null;
        }

        var (mantissa, exponent) = exact;
        exponent += 6;
        if (mantissa.Sign < 0)
        {
            return null;
        }

        if (mantissa.IsZero)
        {
            return (0, false);
        }

        if (exponent >= 0)
        {
            if (exponent > 20)
            {
                return null;
            }

            var whole = mantissa * BigInteger.Pow(10, exponent);
            return whole > MaxPriceMicro ? null : ((long)whole, false);
        }

        if (-exponent > 400)
        {
            return (0, true);
        }

        var divisor = BigInteger.Pow(10, -exponent);
        var quotient = BigInteger.DivRem(mantissa, divisor, out var remainder);
        if (quotient > MaxPriceMicro || (quotient == MaxPriceMicro && !remainder.IsZero))
        {
            return null;
        }

        return ((long)quotient, !remainder.IsZero);
    }

    private static HashSet<string> SetFields(PriceJson? obj) =>
        obj is null ? [] : [.. PriceFields.Where(f => obj[f] is { IsNull: false })];

    /// <summary><c>^[a-z0-9][a-z0-9._:+-]*$</c>.</summary>
    internal static bool IsId(string text)
    {
        if (text.Length == 0 || !IsLowerAlnum(text[0]))
        {
            return false;
        }

        for (var i = 1; i < text.Length; i++)
        {
            if (!IsLowerAlnum(text[i]) && text[i] is not ('.' or '-' or '_' or ':' or '+'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsLowerAlnum(char c) => c is >= 'a' and <= 'z' or >= '0' and <= '9';

    /// <summary>A list of non-empty, trimmed lowercase strings (duplicates are reported across the table).</summary>
    private static List<string>? Aliases(PriceJson? raw)
    {
        if (raw is null)
        {
            return [];
        }

        if (!raw.IsArray)
        {
            return null;
        }

        var values = new List<string>();
        foreach (var item in raw.Items)
        {
            if (item.String is not { Length: > 0 } text || !ModelResolver.IsTrimmedLowercase(text))
            {
                return null;
            }

            values.Add(text);
        }

        return values;
    }

    private static List<string>? LowercaseList(PriceJson? raw) => raw is { IsArray: true } ? LowercaseList(raw.Items) : null;

    /// <summary>Unique, non-empty, trimmed lowercase strings.</summary>
    private static List<string>? LowercaseList(IReadOnlyList<PriceJson> items)
    {
        var values = new List<string>();
        foreach (var item in items)
        {
            if (item.String is not { Length: > 0 } text || !ModelResolver.IsTrimmedLowercase(text))
            {
                return null;
            }

            values.Add(text);
        }

        return values.Distinct(StringComparer.Ordinal).Count() == values.Count ? values : null;
    }

    /// <summary><c>HH:MM-HH:MM</c> with <c>0 ≤ start &lt; end ≤ 24:00</c>, as minutes.</summary>
    private static (int Start, int End)? Window(string? text)
    {
        if (text is not { Length: 11 } || text[2] != ':' || text[5] != '-' || text[8] != ':')
        {
            return null;
        }

        if (Two(text, 0) is not { } h0 || Two(text, 3) is not { } m0 || Two(text, 6) is not { } h1 || Two(text, 9) is not { } m1)
        {
            return null;
        }

        var start = h0 * 60 + m0;
        var end = h1 * 60 + m1;
        return start < end && end <= 1440 ? (start, end) : null;

        static int? Two(string s, int at) =>
            s[at] is >= '0' and <= '9' && s[at + 1] is >= '0' and <= '9' ? (s[at] - '0') * 10 + (s[at + 1] - '0') : null;
    }

    /// <summary>An ISO weekday 1–7 (Python's <c>in range(1, 8)</c> also takes an integral float; never a boolean).</summary>
    private static int? Weekday(PriceJson value)
    {
        if (value.Exact is not { } exact)
        {
            return null;
        }

        var (mantissa, exponent) = exact;
        for (var day = 1; day <= 7; day++)
        {
            var scaled = exponent >= 0 ? mantissa * BigInteger.Pow(10, Math.Min(exponent, 40)) : mantissa;
            var target = exponent >= 0 ? new BigInteger(day) : day * BigInteger.Pow(10, Math.Min(-exponent, 400));
            if (scaled == target)
            {
                return day;
            }
        }

        return null;
    }

    private static string PythonRepr(PriceJson? value) => value?.Kind switch
    {
        PriceJsonKind.String => "'" + value.Text + "'",
        _ => PriceJson.PythonString(value),
    };
}
