using System.Globalization;
using System.Text;
using System.Text.Json;
using AgentSpeed.Core.Pricing;

namespace AgentSpeed.Core.Money;

/// <summary>A display currency (DESIGN 9, <c>spec/assets/currencies.json</c>).</summary>
/// <param name="Code">ISO 4217 code.</param>
/// <param name="Digits">Decimals of an amount.</param>
/// <param name="Symbol">The prefix shown in front of a number.</param>
/// <param name="Symbols">Per UI language (<c>zh-Hant</c>, <c>zh-Hans</c>, <c>en</c>, <c>ja</c>) overrides of <paramref name="Symbol"/>.</param>
/// <param name="Common">Rank in the picker's common group; null = the alphabetical group.</param>
public sealed record Currency(string Code, int Digits, string Symbol, IReadOnlyDictionary<string, string> Symbols, int? Common = null)
{
    public const string UsdCode = "USD";

    /// <summary><c>symbols[language]</c> when present, else <see cref="Symbol"/> (<c>$</c> in English, <c>US$</c> elsewhere).</summary>
    public string SymbolFor(string language) => Symbols.TryGetValue(language, out var symbol) ? symbol : Symbol;

    public bool Equals(Currency? other) =>
        other is not null && Code == other.Code && Digits == other.Digits && Symbol == other.Symbol && Common == other.Common
        && Symbols.Count == other.Symbols.Count
        && Symbols.All(pair => other.Symbols.TryGetValue(pair.Key, out var value) && value == pair.Value);

    public override int GetHashCode() => HashCode.Combine(Code, Digits, Symbol, Common);
}

/// <summary>The bundled units per 1 USD used until the first accepted rate fetch (NETWORK 4).</summary>
/// <param name="Date"><c>YYYY-MM-DD</c>.</param>
public sealed record FallbackRates(string Date, string Source, IReadOnlyDictionary<string, decimal> Rates)
{
    /// <summary>00:00 UTC of <see cref="Date"/>.</summary>
    public long DateMs => UtcDay.InstantMs(Date) ?? 0;
}

/// <summary><c>spec/assets/currencies.json</c>: the supported currencies, their digits and symbols, and the bundled rates.</summary>
public sealed class CurrencyTable
{
    public const string ResourceName = "AgentSpeed.Currencies.json";

    public static readonly IReadOnlyList<string> Languages = ["zh-Hant", "zh-Hans", "en", "ja"];

    /// <summary>The UI language's home currencies, right after USD in the common group (DESIGN 9).</summary>
    public static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> HomeCurrencies =
        new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal)
        {
            ["zh-Hant"] = ["TWD", "HKD", "MOP"],
            ["zh-Hans"] = ["CNY"],
            ["ja"] = ["JPY"],
        };

    private static readonly Lazy<CurrencyTable> LazyBundled = new(LoadBundled);

    private readonly Dictionary<string, Currency> _byCode;

    public CurrencyTable(IReadOnlyList<Currency> currencies, FallbackRates fallbackRates)
    {
        Currencies = currencies;
        FallbackRates = fallbackRates;
        _byCode = new Dictionary<string, Currency>(StringComparer.Ordinal);
        foreach (var currency in currencies)
        {
            _byCode[currency.Code] = currency;
        }

        Codes = _byCode.Keys.ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>The table bundled with this build.</summary>
    public static CurrencyTable Bundled => LazyBundled.Value;

    public IReadOnlyList<Currency> Currencies { get; }

    public FallbackRates FallbackRates { get; }

    public IReadOnlySet<string> Codes { get; }

    /// <exception cref="FormatException">Not a schema-1 currency table.</exception>
    public static CurrencyTable Parse(ReadOnlySpan<byte> utf8)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(utf8.ToArray());
        }
        catch (JsonException)
        {
            throw new FormatException("schema or currencies");
        }

        using (document)
        {
            var root = RateJson.Members(document.RootElement);
            if (root is null || RateJson.Int64(root.GetValueOrDefault("schema")) != 1
                || root.GetValueOrDefault("currencies") is not { ValueKind: JsonValueKind.Array } list)
            {
                throw new FormatException("schema or currencies");
            }

            var currencies = new List<Currency>();
            foreach (var item in list.EnumerateArray())
            {
                var entry = RateJson.Members(item);
                if (entry is null || RateJson.String(entry.GetValueOrDefault("code")) is not { } code
                    || RateJson.Int64(entry.GetValueOrDefault("digits")) is not { } digits || digits is < 0 or > 28
                    || RateJson.String(entry.GetValueOrDefault("symbol")) is not { } symbol)
                {
                    throw new FormatException("currency entry");
                }

                var symbols = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var (language, value) in RateJson.Members(entry.GetValueOrDefault("symbols")) ?? new Dictionary<string, JsonElement>())
                {
                    if (RateJson.String(value) is { } text)
                    {
                        symbols[language] = text;
                    }
                }

                var common = RateJson.Int64(entry.GetValueOrDefault("common")) is { } rank and >= int.MinValue and <= int.MaxValue
                    ? (int?)rank
                    : null;
                currencies.Add(new Currency(code, (int)digits, symbol, symbols, common));
            }

            var fallback = RateJson.Members(root.GetValueOrDefault("fallbackRates"));
            if (fallback is null || RateJson.String(fallback.GetValueOrDefault("date")) is not { } date
                || RateJson.String(fallback.GetValueOrDefault("source")) is not { } source
                || RateJson.Members(fallback.GetValueOrDefault("rates")) is not { } raw)
            {
                throw new FormatException("fallbackRates");
            }

            var rates = new Dictionary<string, decimal>(StringComparer.Ordinal);
            foreach (var (code, value) in raw)
            {
                if (RateJson.Decimal(value) is not { } rate || rate <= 0)
                {
                    throw new FormatException("fallback rate " + code);
                }

                rates[code] = rate;
            }

            return new CurrencyTable(currencies, new FallbackRates(date, source, rates));
        }
    }

    public Currency? Find(string code) => _byCode.GetValueOrDefault(code);

    /// <summary>The currency for <paramref name="code"/>, else USD.</summary>
    public Currency CurrencyOrUsd(string code) => _byCode.GetValueOrDefault(code) ?? _byCode[Currency.UsdCode];

    /// <summary>The picker's common group: USD, the UI language's home currencies, then the remaining <c>common</c> ranks.</summary>
    public IReadOnlyList<Currency> CommonGroup(string language)
    {
        var order = new List<string> { Currency.UsdCode };
        foreach (var code in HomeCurrencies.GetValueOrDefault(language) ?? [])
        {
            if (!order.Contains(code) && _byCode.ContainsKey(code))
            {
                order.Add(code);
            }
        }

        foreach (var currency in Currencies.Where(c => c.Common is not null).OrderBy(c => c.Common))
        {
            if (!order.Contains(currency.Code))
            {
                order.Add(currency.Code);
            }
        }

        return [.. order.Where(_byCode.ContainsKey).Select(code => _byCode[code])];
    }

    /// <summary>Every other currency, sorted by <paramref name="localizedName"/> in the UI language's collation (then code).</summary>
    public IReadOnlyList<Currency> OtherGroup(string language, Func<Currency, string> localizedName)
    {
        ArgumentNullException.ThrowIfNull(localizedName);
        var common = CommonGroup(language).Select(c => c.Code).ToHashSet(StringComparer.Ordinal);
        var compare = CultureOf(language).CompareInfo;
        var others = Currencies.Where(c => !common.Contains(c.Code)).Select(c => (Currency: c, Name: localizedName(c))).ToList();
        others.Sort((lhs, rhs) =>
        {
            var order = compare.Compare(lhs.Name, rhs.Name, CompareOptions.IgnoreCase);
            return order != 0 ? order : string.CompareOrdinal(lhs.Currency.Code, rhs.Currency.Code);
        });
        return [.. others.Select(item => item.Currency)];
    }

    /// <summary>
    /// Search results as one ranked list (DESIGN 9): code prefix matches first, then matches at the start of any word of
    /// the localized or English name or of the symbol (<c>nt</c> finds TWD through <c>NT$</c>); case-, width- and
    /// diacritic-insensitive. Within a rank the picker order is kept (common group first, then the others by localized
    /// name). An empty query returns nothing.
    /// </summary>
    public IReadOnlyList<Currency> Search(
        string query,
        string language,
        Func<Currency, string> localizedName,
        Func<Currency, string> englishName)
    {
        ArgumentNullException.ThrowIfNull(englishName);
        var needle = Fold((query ?? string.Empty).Trim());
        if (needle.Length == 0)
        {
            return [];
        }

        var target = Runes(needle);
        var codeMatches = new List<Currency>();
        var nameMatches = new List<Currency>();
        foreach (var currency in CommonGroup(language).Concat(OtherGroup(language, localizedName)))
        {
            if (Fold(currency.Code).StartsWith(needle, StringComparison.Ordinal))
            {
                codeMatches.Add(currency);
            }
            else if (new[] { localizedName(currency), englishName(currency), currency.SymbolFor(language), currency.Symbol }
                     .Any(text => WordStarts(Runes(Fold(text)), target)))
            {
                nameMatches.Add(currency);
            }
        }

        return [.. codeMatches, .. nameMatches];
    }

    /// <summary>Lowercased, width-folded (full-width letters become ASCII), without diacritics.</summary>
    internal static string Fold(string text)
    {
        string decomposed;
        try
        {
            decomposed = text.Normalize(NormalizationForm.FormKD);
        }
        catch (ArgumentException)
        {
            decomposed = text;
        }

        var builder = new StringBuilder(decomposed.Length);
        foreach (var rune in decomposed.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(Rune.ToLowerInvariant(rune).ToString());
            }
        }

        return builder.ToString();
    }

    /// <summary>
    /// Whether <paramref name="needle"/> starts any word of <paramref name="haystack"/>: the whole text, after a space,
    /// punctuation or symbol, or at any CJK character (CJK names have no spaces, so every character starts a word).
    /// </summary>
    internal static bool WordStarts(Rune[] haystack, Rune[] needle)
    {
        if (needle.Length == 0 || haystack.Length < needle.Length)
        {
            return false;
        }

        for (var start = 0; start <= haystack.Length - needle.Length; start++)
        {
            var isBoundary = start == 0 || !IsWordRune(haystack[start - 1]) || IsIdeographic(haystack[start]);
            if (isBoundary && haystack.AsSpan(start, needle.Length).SequenceEqual(needle))
            {
                return true;
            }
        }

        return false;
    }

    internal static Rune[] Runes(string text) => [.. text.EnumerateRunes()];

    private static bool IsWordRune(Rune rune) =>
        Rune.IsLetter(rune) || Rune.IsNumber(rune) || Rune.GetUnicodeCategory(rune) == UnicodeCategory.SpacingCombiningMark;

    private static bool IsIdeographic(Rune rune) => rune.Value switch
    {
        0x3006 or 0x3007 => true,
        >= 0x3021 and <= 0x3029 => true,
        >= 0x3038 and <= 0x303A => true,
        >= 0x3040 and <= 0x30FF => true,
        >= 0x3400 and <= 0x4DBF => true,
        >= 0x4E00 and <= 0x9FFF => true,
        >= 0xF900 and <= 0xFAFF => true,
        >= 0x17000 and <= 0x18CFF => true,
        >= 0x1B170 and <= 0x1B2FF => true,
        >= 0x20000 and <= 0x323AF => true,
        _ => false,
    };

    private static CultureInfo CultureOf(string language)
    {
        try
        {
            return CultureInfo.GetCultureInfo(language);
        }
        catch (CultureNotFoundException)
        {
            return CultureInfo.InvariantCulture;
        }
    }

    private static CurrencyTable LoadBundled()
    {
        using var stream = typeof(CurrencyTable).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException("The bundled currency table is missing: " + ResourceName);
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        try
        {
            return Parse(buffer.ToArray());
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException("The bundled currency table does not parse; run python3 spec/tools/prices.py", ex);
        }
    }
}
