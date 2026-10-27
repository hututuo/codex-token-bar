using System.Globalization;
using System.Text;

namespace AgentSpeed.Core.Reporting;

/// <summary>
/// An ordered JSON document the client writes: report bodies, registrations and renames (REPORTING 2.3, 6.7). Members
/// keep their order, integers are written without a fraction and rounded numbers with at most their decimals.
/// </summary>
public abstract record ReportJson
{
    private ReportJson()
    {
    }

    public static ReportJson Null { get; } = new NullValue();

    public static ReportJson Of(bool value) => new BoolValue(value);

    public static ReportJson Of(long value) => new IntValue(value);

    public static ReportJson Of(string value) => new StringValue(value);

    /// <summary>A value rounded half away from zero to <paramref name="decimals"/> places, without trailing zeros.</summary>
    public static ReportJson Decimal(double value, int decimals) => new DecimalValue(value, decimals);

    /// <summary>An integer, or <c>null</c> (traffic rates before two samples).</summary>
    public static ReportJson OfOptional(long? value) => value is { } v ? new IntValue(v) : Null;

    public static ReportJson Array(IEnumerable<ReportJson> items) => new ArrayValue([.. items]);

    public static ReportJson Object(params (string Key, ReportJson Value)[] members) => new ObjectValue([.. members]);

    public static ReportJson Object(IEnumerable<(string Key, ReportJson Value)> members) => new ObjectValue([.. members]);

    /// <summary>The member <paramref name="key"/> of an object, or null.</summary>
    public ReportJson? this[string key] => this is ObjectValue o ? o.Members.FirstOrDefault(m => m.Key == key).Value : null;

    /// <summary>Compact UTF-8 without a byte order mark, as sent (REPORTING 2.3).</summary>
    public byte[] ToCompactBytes() => Encoding.UTF8.GetBytes(ToCompactString());

    public string ToCompactString()
    {
        var builder = new StringBuilder(512);
        Write(builder, pretty: false, indent: 0);
        return builder.ToString();
    }

    /// <summary>Two-space indentation, <c>"key": value</c>, for the preview (DESIGN 11).</summary>
    public string ToPrettyString()
    {
        var builder = new StringBuilder(1024);
        Write(builder, pretty: true, indent: 0);
        return builder.ToString();
    }

    /// <summary>The pretty text split into runs, so a view can color keys apart from values.</summary>
    public IReadOnlyList<ReportJsonToken> ToPrettyTokens()
    {
        var tokens = new List<ReportJsonToken>(128);
        Tokenize(tokens, 0);
        return tokens;
    }

    private void Write(StringBuilder output, bool pretty, int indent)
    {
        switch (this)
        {
            case NullValue:
                output.Append("null");
                break;
            case BoolValue b:
                output.Append(b.Value ? "true" : "false");
                break;
            case IntValue i:
                output.Append(i.Value.ToString(CultureInfo.InvariantCulture));
                break;
            case DecimalValue d:
                output.Append(Number(d.Value, d.Decimals));
                break;
            case StringValue s:
                Quote(output, s.Value);
                break;
            case ArrayValue a:
                if (a.Items.Length == 0)
                {
                    output.Append("[]");
                    break;
                }

                output.Append('[');
                for (var index = 0; index < a.Items.Length; index++)
                {
                    if (index > 0)
                    {
                        output.Append(',');
                    }

                    if (pretty)
                    {
                        output.Append('\n').Append(' ', (indent + 1) * 2);
                    }

                    a.Items[index].Write(output, pretty, indent + 1);
                }

                if (pretty)
                {
                    output.Append('\n').Append(' ', indent * 2);
                }

                output.Append(']');
                break;
            case ObjectValue o:
                if (o.Members.Length == 0)
                {
                    output.Append("{}");
                    break;
                }

                output.Append('{');
                for (var index = 0; index < o.Members.Length; index++)
                {
                    if (index > 0)
                    {
                        output.Append(',');
                    }

                    if (pretty)
                    {
                        output.Append('\n').Append(' ', (indent + 1) * 2);
                    }

                    Quote(output, o.Members[index].Key);
                    output.Append(pretty ? ": " : ":");
                    o.Members[index].Value.Write(output, pretty, indent + 1);
                }

                if (pretty)
                {
                    output.Append('\n').Append(' ', indent * 2);
                }

                output.Append('}');
                break;
        }
    }

    private void Tokenize(List<ReportJsonToken> tokens, int indent)
    {
        switch (this)
        {
            case StringValue s:
                tokens.Add(new ReportJsonToken(Quoted(s.Value), ReportJsonTokenKind.String));
                break;
            case ArrayValue a:
                if (a.Items.Length == 0)
                {
                    tokens.Add(new ReportJsonToken("[]", ReportJsonTokenKind.Punctuation));
                    break;
                }

                tokens.Add(new ReportJsonToken("[", ReportJsonTokenKind.Punctuation));
                for (var index = 0; index < a.Items.Length; index++)
                {
                    tokens.Add(new ReportJsonToken((index > 0 ? "," : string.Empty) + "\n" + new string(' ', (indent + 1) * 2),
                        ReportJsonTokenKind.Punctuation));
                    a.Items[index].Tokenize(tokens, indent + 1);
                }

                tokens.Add(new ReportJsonToken("\n" + new string(' ', indent * 2) + "]", ReportJsonTokenKind.Punctuation));
                break;
            case ObjectValue o:
                if (o.Members.Length == 0)
                {
                    tokens.Add(new ReportJsonToken("{}", ReportJsonTokenKind.Punctuation));
                    break;
                }

                tokens.Add(new ReportJsonToken("{", ReportJsonTokenKind.Punctuation));
                for (var index = 0; index < o.Members.Length; index++)
                {
                    tokens.Add(new ReportJsonToken((index > 0 ? "," : string.Empty) + "\n" + new string(' ', (indent + 1) * 2),
                        ReportJsonTokenKind.Punctuation));
                    tokens.Add(new ReportJsonToken(Quoted(o.Members[index].Key), ReportJsonTokenKind.Key));
                    tokens.Add(new ReportJsonToken(": ", ReportJsonTokenKind.Punctuation));
                    o.Members[index].Value.Tokenize(tokens, indent + 1);
                }

                tokens.Add(new ReportJsonToken("\n" + new string(' ', indent * 2) + "}", ReportJsonTokenKind.Punctuation));
                break;
            default:
                var text = new StringBuilder();
                Write(text, pretty: false, indent: 0);
                tokens.Add(new ReportJsonToken(text.ToString(), ReportJsonTokenKind.Number));
                break;
        }
    }

    /// <summary>Half away from zero (REPORTING 6.7), at most <paramref name="decimals"/> places, no trailing zeros, never <c>-0</c>.</summary>
    public static string Number(double value, int decimals)
    {
        if (!double.IsFinite(value))
        {
            return "0";
        }

        var rounded = Round(value, decimals);
        if (rounded == 0)
        {
            return "0";
        }

        var text = rounded.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        if (text.Contains('.', StringComparison.Ordinal))
        {
            text = text.TrimEnd('0').TrimEnd('.');
        }

        return text;
    }

    /// <summary>Half away from zero to <paramref name="decimals"/> places (0 for a non-finite value).</summary>
    public static double Round(double value, int decimals)
    {
        if (!double.IsFinite(value))
        {
            return 0;
        }

        var scale = Math.Pow(10, decimals);
        return Math.Round(value * scale, MidpointRounding.AwayFromZero) / scale;
    }

    private static string Quoted(string text)
    {
        var builder = new StringBuilder(text.Length + 2);
        Quote(builder, text);
        return builder.ToString();
    }

    /// <summary>JSON string with only the required escapes; other characters stay UTF-8 (like <c>ensure_ascii=False</c>).</summary>
    private static void Quote(StringBuilder output, string text)
    {
        output.Append('"');
        foreach (var c in text)
        {
            switch (c)
            {
                case '"':
                    output.Append("\\\"");
                    break;
                case '\\':
                    output.Append("\\\\");
                    break;
                case '\n':
                    output.Append("\\n");
                    break;
                case '\r':
                    output.Append("\\r");
                    break;
                case '\t':
                    output.Append("\\t");
                    break;
                case '\b':
                    output.Append("\\b");
                    break;
                case '\f':
                    output.Append("\\f");
                    break;
                default:
                    if (c < 0x20)
                    {
                        output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        output.Append(c);
                    }

                    break;
            }
        }

        output.Append('"');
    }

    private sealed record NullValue : ReportJson;

    private sealed record BoolValue(bool Value) : ReportJson;

    private sealed record IntValue(long Value) : ReportJson;

    private sealed record DecimalValue(double Value, int Decimals) : ReportJson;

    private sealed record StringValue(string Value) : ReportJson;

    private sealed record ArrayValue(ReportJson[] Items) : ReportJson
    {
        public bool Equals(ArrayValue? other) => other is not null && Items.SequenceEqual(other.Items);

        public override int GetHashCode() => Items.Length;
    }

    private sealed record ObjectValue((string Key, ReportJson Value)[] Members) : ReportJson
    {
        public bool Equals(ObjectValue? other) => other is not null && Members.SequenceEqual(other.Members);

        public override int GetHashCode() => Members.Length;
    }
}

public enum ReportJsonTokenKind
{
    Key,
    String,
    Number,
    Punctuation,
}

/// <summary>One run of the pretty-printed preview.</summary>
public readonly record struct ReportJsonToken(string Text, ReportJsonTokenKind Kind);
