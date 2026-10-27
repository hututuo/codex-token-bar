using System.Collections.Concurrent;
using System.Globalization;
using System.Text;

namespace AgentSpeed.Core.Pricing;

public enum ResolutionKind : byte
{
    Priced,
    Free,
    Unknown,
}

/// <summary>What a response's model resolves to (METRICS 9.2).</summary>
/// <param name="Index">The entry in <see cref="PriceTable.Models"/> that decided (priced, or free by its entry); -1 otherwise.</param>
/// <param name="Fast">The id itself selects fast mode.</param>
public readonly record struct ModelResolution(ResolutionKind Kind, int Index = -1, bool Fast = false, string? Reason = null)
{
    public static ModelResolution Free(int index = -1) => new(ResolutionKind.Free, index);

    public static ModelResolution UnknownBecause(string reason) => new(ResolutionKind.Unknown, Reason: reason);
}

/// <summary>
/// Model resolution of METRICS 9.2. Strings are compared ordinally, the way <c>spec/tools/prices.py</c> compares code
/// points, and the character classes follow Python's (<c>\s</c>, <c>\d</c>, <c>str.strip</c>, <c>str.lower</c>).
/// Thread-safe.
/// </summary>
public sealed class ModelResolver
{
    private const int CacheLimit = 4096;

    private readonly PriceNormalization _normalize;
    private readonly Dictionary<string, int> _byKey = new(StringComparer.Ordinal);
    private readonly bool[] _free;
    private readonly bool[] _hasFast;
    private readonly Dictionary<string, string> _unknownExact = new(StringComparer.Ordinal);
    private readonly List<(string Prefix, string Reason)> _unknownPrefixes = [];
    private readonly ConcurrentDictionary<(string? Provider, string? Model), ModelResolution> _cache = new();

    internal ModelResolver(PriceNormalization normalize, IReadOnlyList<PriceModel> models, IReadOnlyList<UnknownModelRule> unknown)
    {
        _normalize = normalize;
        _free = new bool[models.Count];
        _hasFast = new bool[models.Count];
        for (var i = 0; i < models.Count; i++)
        {
            _byKey[models[i].Id] = i;
            foreach (var alias in models[i].Aliases)
            {
                _byKey[alias] = i;
            }

            _free[i] = models[i].IsFree;
            _hasFast[i] = models[i].Fast is not null;
        }

        foreach (var rule in unknown)
        {
            if (rule.IsPrefix)
            {
                _unknownPrefixes.Add((rule.Value, rule.Reason));
            }
            else
            {
                _unknownExact[rule.Value] = rule.Reason;
            }
        }
    }

    public ModelResolution Resolve(string? model, string? provider)
    {
        var key = (provider, model);
        if (_cache.TryGetValue(key, out var hit))
        {
            return hit;
        }

        var result = Compute(model, provider);
        if (_cache.Count >= CacheLimit)
        {
            _cache.Clear();
        }

        _cache[key] = result;
        return result;
    }

    /// <summary>Step 1 of METRICS 9.2: a local runtime's provider with a model that does not run in its cloud.</summary>
    public bool IsLocalProvider(string? model, string? provider) =>
        provider is not null && Contains(_normalize.FreeProviders, Lower(Strip(provider)))
        && !(model is not null && EndsWithAny(Lower(Strip(model)), _normalize.CloudSuffixes));

    private ModelResolution Compute(string? model, string? provider)
    {
        if (IsLocalProvider(model, provider))
        {
            return ModelResolution.Free();
        }

        if (model is null || Strip(model).Length == 0)
        {
            return ModelResolution.UnknownBecause("no model");
        }

        var seen = new HashSet<(string, bool)>();
        foreach (var (_, key, fast) in Candidates(model))
        {
            if (key is null)
            {
                return ModelResolution.Free();
            }

            if (key.Length == 0 || !seen.Add((key, fast)))
            {
                continue;
            }

            if (Lookup(key, fast) is { } found)
            {
                return found;
            }
        }

        return ModelResolution.UnknownBecause("not in table");
    }

    private ModelResolution? Lookup(string key, bool fast)
    {
        if (_byKey.TryGetValue(key, out var index))
        {
            if (_free[index])
            {
                return ModelResolution.Free(index);
            }

            if (fast && !_hasFast[index])
            {
                return ModelResolution.UnknownBecause("no fast-mode price");
            }

            return new ModelResolution(ResolutionKind.Priced, index, fast);
        }

        if (_unknownExact.TryGetValue(key, out var reason))
        {
            return ModelResolution.UnknownBecause(reason);
        }

        foreach (var (prefix, prefixReason) in _unknownPrefixes)
        {
            if (key.StartsWith(prefix, StringComparison.Ordinal))
            {
                return ModelResolution.UnknownBecause(prefixReason);
            }
        }

        return null;
    }

    /// <summary>The normalization steps of METRICS 9.2, in order; a null key is the <c>free</c> step.</summary>
    internal IEnumerable<(string Step, string? Key, bool Fast)> Candidates(string model)
    {
        var n = _normalize;
        var k = Lower(Strip(CollapseWhitespace(RemoveBrackets(model))));
        yield return ("exact", k, false);
        var slash = k.LastIndexOf('/');
        if (slash >= 0)
        {
            k = k[(slash + 1)..];
            yield return ("route", k, false);
        }

        foreach (var region in n.BedrockRegions)
        {
            var head = region + ".";
            if (!k.StartsWith(head, StringComparison.Ordinal))
            {
                continue;
            }

            var rest = k[head.Length..];
            if (n.BedrockVendors.Any(v => rest.StartsWith(v + ".", StringComparison.Ordinal)))
            {
                k = rest;
                break;
            }
        }

        foreach (var vendor in n.BedrockVendors)
        {
            var head = vendor + ".";
            if (k.StartsWith(head, StringComparison.Ordinal))
            {
                k = RemoveBedrockVersion(k[head.Length..]);
                break;
            }
        }

        k = RemoveVertexTag(VertexDate(k));
        yield return ("cloud", k, false);
        foreach (var suffix in n.FreeSuffixes)
        {
            if (k.Length > suffix.Length && k.EndsWith(suffix, StringComparison.Ordinal))
            {
                yield return ("free", null, false);
                yield break;
            }
        }

        var stripped = true;
        while (stripped)
        {
            stripped = false;
            foreach (var suffix in n.VariantSuffixes)
            {
                if (k.Length > suffix.Length && k.EndsWith(suffix, StringComparison.Ordinal))
                {
                    k = k[..^suffix.Length];
                    stripped = true;
                }
            }
        }

        yield return ("variant", k, false);
        foreach (var (prefix, to) in n.Rewrites)
        {
            if (k.StartsWith(prefix, StringComparison.Ordinal))
            {
                k = to + k[prefix.Length..];
                break;
            }
        }

        yield return ("rewrite", k, false);
        var fast = false;
        foreach (var suffix in n.FastSuffixes)
        {
            if (k.Length > suffix.Length && k.EndsWith(suffix, StringComparison.Ordinal))
            {
                k = k[..^suffix.Length];
                fast = true;
                break;
            }
        }

        if (fast)
        {
            yield return ("fast", k, true);
        }

        if (n.DateSuffixPrefixes.Any(p => k.StartsWith(p, StringComparison.Ordinal)))
        {
            k = RemoveDateSuffix(k);
        }

        yield return ("date", k, fast);
        foreach (var (prefix, suffixes) in n.ModifierSuffixes)
        {
            if (!k.StartsWith(prefix, StringComparison.Ordinal))
            {
                continue;
            }

            stripped = true;
            while (stripped)
            {
                stripped = false;
                foreach (var suffix in suffixes)
                {
                    if (k.Length > prefix.Length + suffix.Length && k.EndsWith(suffix, StringComparison.Ordinal))
                    {
                        k = k[..^suffix.Length];
                        stripped = true;
                    }
                }
            }

            break;
        }

        yield return ("modifier", k, fast);
        if (n.DotHyphenPrefixes.Any(p => k.StartsWith(p, StringComparison.Ordinal)))
        {
            k = k.Replace('.', '-');
        }

        yield return ("dotHyphen", k, fast);
    }

    // Python string semantics.

    /// <summary><c>str.isspace()</c>: the ASCII separators (including 0x1C–0x1F) and Unicode White_Space.</summary>
    internal static bool IsSpace(char c) => c is >= '\t' and <= '\r' or >= '\x1c' and <= ' ' || (c >= 0x80 && char.IsWhiteSpace(c));

    internal static string Strip(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsSpace(text[start]))
        {
            start++;
        }

        while (end > start && IsSpace(text[end - 1]))
        {
            end--;
        }

        return start == 0 && end == text.Length ? text : text[start..end];
    }

    internal static string Lower(string text) => text.ToLowerInvariant();

    /// <summary><c>v == v.strip().lower()</c>.</summary>
    internal static bool IsTrimmedLowercase(string? text) => text is not null && Lower(Strip(text)) == text;

    private static bool Contains(IReadOnlyList<string> list, string value)
    {
        foreach (var item in list)
        {
            if (string.Equals(item, value, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static bool EndsWithAny(string text, IReadOnlyList<string> suffixes)
    {
        foreach (var suffix in suffixes)
        {
            if (text.EndsWith(suffix, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary><c>\d</c>: a Unicode decimal digit.</summary>
    private static bool IsDigit(string text, int index) =>
        CharUnicodeInfo.GetUnicodeCategory(text, index) == UnicodeCategory.DecimalDigitNumber;

    /// <summary><c>\[[^\]]*\]</c> → one space.</summary>
    private static string RemoveBrackets(string text)
    {
        if (text.IndexOf('[') < 0)
        {
            return text;
        }

        var builder = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var close = text[i] == '[' ? text.IndexOf(']', i + 1) : -1;
            if (close >= 0)
            {
                builder.Append(' ');
                i = close + 1;
            }
            else
            {
                builder.Append(text[i]);
                i++;
            }
        }

        return builder.ToString();
    }

    /// <summary><c>\s+</c> → one space.</summary>
    private static string CollapseWhitespace(string text)
    {
        var builder = new StringBuilder(text.Length);
        var inRun = false;
        foreach (var c in text)
        {
            if (IsSpace(c))
            {
                if (!inRun)
                {
                    builder.Append(' ');
                }

                inRun = true;
            }
            else
            {
                builder.Append(c);
                inRun = false;
            }
        }

        return builder.ToString();
    }

    /// <summary>Removes a trailing <c>-v\d+(:\d+)?</c>.</summary>
    private static string RemoveBedrockVersion(string key)
    {
        for (var i = 0; i + 2 < key.Length; i++)
        {
            if (key[i] == '-' && key[i + 1] == 'v' && IsVersionTail(key, i + 2))
            {
                return key[..i];
            }
        }

        return key;
    }

    private static bool IsVersionTail(string key, int start)
    {
        var i = start;
        var digits = 0;
        while (i < key.Length && IsDigit(key, i))
        {
            i += char.IsSurrogatePair(key, i) ? 2 : 1;
            digits++;
        }

        if (digits == 0)
        {
            return false;
        }

        if (i == key.Length)
        {
            return true;
        }

        if (key[i] != ':')
        {
            return false;
        }

        i++;
        if (i == key.Length)
        {
            return false;
        }

        while (i < key.Length)
        {
            if (!IsDigit(key, i))
            {
                return false;
            }

            i += char.IsSurrogatePair(key, i) ? 2 : 1;
        }

        return true;
    }

    /// <summary>A trailing <c>@</c> + 8 digits becomes <c>-</c> + the digits.</summary>
    private static string VertexDate(string key)
    {
        var at = TrailingDigitsStart(key, 8);
        return at > 0 && key[at - 1] == '@' ? key[..(at - 1)] + "-" + key[at..] : key;
    }

    /// <summary>Removes a trailing <c>@…</c> that contains no <c>@</c> or <c>/</c>.</summary>
    private static string RemoveVertexTag(string key)
    {
        var at = key.LastIndexOf('@');
        return at < 0 || key.IndexOf('/', at) >= 0 ? key : key[..at];
    }

    /// <summary>Removes a trailing <c>-</c> + 8 digits.</summary>
    private static string RemoveDateSuffix(string key)
    {
        var at = TrailingDigitsStart(key, 8);
        return at > 0 && key[at - 1] == '-' ? key[..(at - 1)] : key;
    }

    /// <summary>The index where exactly <paramref name="count"/> trailing digits start, or -1.</summary>
    private static int TrailingDigitsStart(string key, int count)
    {
        var i = key.Length;
        for (var n = 0; n < count; n++)
        {
            if (i == 0)
            {
                return -1;
            }

            var width = i >= 2 && char.IsSurrogatePair(key[i - 2], key[i - 1]) ? 2 : 1;
            if (!IsDigit(key, i - width))
            {
                return -1;
            }

            i -= width;
        }

        return i;
    }
}
