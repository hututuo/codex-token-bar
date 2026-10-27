using System.Globalization;
using System.Numerics;
using System.Text.Json;

namespace AgentSpeed.Core.Pricing;

internal enum PriceJsonKind : byte
{
    Null,
    Bool,
    Number,
    String,
    Array,
    Object,
}

/// <summary>
/// A JSON value as Python's <c>json</c> module sees it (METRICS 9.1, NETWORK 3): numbers keep their literal so prices
/// convert exactly and integers stay distinguishable from fractions; objects keep the last value of a repeated key.
/// </summary>
internal sealed class PriceJson
{
    private static readonly JsonReaderOptions ReaderOptions = new() { MaxDepth = 64 };

    private PriceJson(PriceJsonKind kind)
    {
        Kind = kind;
    }

    public PriceJsonKind Kind { get; }

    public bool BoolValue { get; private init; }

    /// <summary>The string value, or the literal text of a number.</summary>
    public string? Text { get; private init; }

    public IReadOnlyList<PriceJson> Items { get; private init; } = [];

    public IReadOnlyDictionary<string, PriceJson> Members { get; private init; } = new Dictionary<string, PriceJson>();

    /// <summary>Member names in first-occurrence order.</summary>
    public IReadOnlyList<string> Keys { get; private init; } = [];

    public bool IsNull => Kind == PriceJsonKind.Null;

    public bool IsObject => Kind == PriceJsonKind.Object;

    public bool IsArray => Kind == PriceJsonKind.Array;

    public string? String => Kind == PriceJsonKind.String ? Text : null;

    /// <summary>No fraction and no exponent: Python reads it as an <c>int</c>.</summary>
    public bool IsInteger => Kind == PriceJsonKind.Number && Text!.AsSpan().IndexOfAny('.', 'e', 'E') < 0;

    /// <summary>An integer literal that fits in 64 bits (never a boolean or a fraction).</summary>
    public long? Int64 =>
        IsInteger && long.TryParse(Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    public PriceJson? this[string key] =>
        Kind == PriceJsonKind.Object && Members.TryGetValue(key, out var value) ? value : null;

    /// <summary>
    /// The exact value as <c>spec/tools/prices.py</c> sees it, as <c>mantissa × 10^exponent</c>: an integer literal
    /// exactly, any other literal as its nearest double written in the shortest form that reads back (Python's
    /// <c>Decimal(repr(float))</c>). Null when it is not a finite number.
    /// </summary>
    public (BigInteger Mantissa, int Exponent)? Exact
    {
        get
        {
            if (Kind != PriceJsonKind.Number)
            {
                return null;
            }

            if (IsInteger)
            {
                return ParseDecimalText(Text!);
            }

            if (!double.TryParse(Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || !double.IsFinite(value))
            {
                return null;
            }

            return ParseDecimalText(value.ToString("R", CultureInfo.InvariantCulture));
        }
    }

    public static PriceJson? Parse(ReadOnlySpan<byte> utf8)
    {
        try
        {
            var reader = new Utf8JsonReader(utf8, ReaderOptions);
            if (!reader.Read())
            {
                return null;
            }

            var value = ReadValue(ref reader);
            return reader.Read() ? null : value;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>Python truthiness.</summary>
    public static bool Truthy(PriceJson? value) => value?.Kind switch
    {
        null or PriceJsonKind.Null => false,
        PriceJsonKind.Bool => value.BoolValue,
        PriceJsonKind.Number => value.Exact is not { } exact || !exact.Mantissa.IsZero,
        PriceJsonKind.String => value.Text!.Length > 0,
        PriceJsonKind.Array => value.Items.Count > 0,
        _ => value.Members.Count > 0,
    };

    /// <summary><c>str()</c> of a value, for messages and the <c>str(...).startswith("https://")</c> checks.</summary>
    public static string PythonString(PriceJson? value) => value?.Kind switch
    {
        PriceJsonKind.String or PriceJsonKind.Number => value.Text!,
        PriceJsonKind.Bool => value.BoolValue ? "True" : "False",
        null or PriceJsonKind.Null => "None",
        _ => "…",
    };

    /// <summary><c>[-]digits[.digits][(e|E)[+-]digits]</c> as an exact mantissa and power of ten.</summary>
    internal static (BigInteger Mantissa, int Exponent)? ParseDecimalText(string text)
    {
        var span = text.AsSpan();
        var negative = false;
        if (span.Length > 0 && span[0] is '-' or '+')
        {
            negative = span[0] == '-';
            span = span[1..];
        }

        var mantissa = BigInteger.Zero;
        var exponent = 0;
        var digits = 0;
        var index = 0;
        var seenDot = false;
        for (; index < span.Length; index++)
        {
            var c = span[index];
            if (c is >= '0' and <= '9')
            {
                mantissa = mantissa * 10 + (c - '0');
                digits++;
                if (seenDot)
                {
                    exponent--;
                }
            }
            else if (c == '.' && !seenDot)
            {
                seenDot = true;
            }
            else
            {
                break;
            }
        }

        if (digits == 0)
        {
            return null;
        }

        if (index < span.Length)
        {
            if (span[index] is not ('e' or 'E')
                || !int.TryParse(span[(index + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var power)
                || power is > 100_000 or < -100_000)
            {
                return null;
            }

            exponent += power;
        }

        return (negative ? -mantissa : mantissa, exponent);
    }

    private static PriceJson ReadValue(ref Utf8JsonReader reader)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return new PriceJson(PriceJsonKind.Null);
            case JsonTokenType.True:
            case JsonTokenType.False:
                return new PriceJson(PriceJsonKind.Bool) { BoolValue = reader.TokenType == JsonTokenType.True };
            case JsonTokenType.Number:
                return new PriceJson(PriceJsonKind.Number) { Text = System.Text.Encoding.UTF8.GetString(reader.ValueSpan) };
            case JsonTokenType.String:
                return new PriceJson(PriceJsonKind.String) { Text = reader.GetString() };
            case JsonTokenType.StartArray:
            {
                var items = new List<PriceJson>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                {
                    items.Add(ReadValue(ref reader));
                }

                return new PriceJson(PriceJsonKind.Array) { Items = items };
            }

            case JsonTokenType.StartObject:
            {
                var members = new Dictionary<string, PriceJson>(StringComparer.Ordinal);
                var keys = new List<string>();
                while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
                {
                    var name = reader.GetString()!;
                    reader.Read();
                    if (!members.ContainsKey(name))
                    {
                        keys.Add(name);
                    }

                    members[name] = ReadValue(ref reader);
                }

                return new PriceJson(PriceJsonKind.Object) { Members = members, Keys = keys };
            }

            default:
                throw new JsonException("Unexpected token " + reader.TokenType);
        }
    }
}
