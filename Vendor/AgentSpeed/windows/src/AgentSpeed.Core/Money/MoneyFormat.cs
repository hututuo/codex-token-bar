using System.Buffers;
using System.Globalization;
using System.Text;

namespace AgentSpeed.Core.Money;

/// <summary>The two money forms of DESIGN 9: a live value per second, or an amount (today, history, breakdowns, tooltips).</summary>
public enum MoneyForm
{
    Rate,
    Amount,
}

/// <summary>
/// A formatted money value: the digits alone, and the full text (an amount with its symbol in front, a rate followed by
/// <c> &lt;symbol&gt;/s</c>).
/// </summary>
public readonly record struct FormattedMoney(string Number, string Text, string Symbol);

/// <summary>
/// DESIGN 9 money formatting, in decimal arithmetic with half-up rounding, digit for digit like the reference formatter in
/// <c>spec/tools/prices.py</c>. Values are never negative and never in scientific notation.
/// </summary>
public static class MoneyFormat
{
    public const string BelowSmallest = "<0.000001";
    public const string NoBreakSpace = " ";

    private const decimal Tiny = 0.0000005m;
    private const decimal Million = 1_000_000m;
    private const decimal LargestPower = 1e27m;
    private const int MaxScale = 28;

    /// <summary><c>costMicroUsd / 1 000 000 × rate</c>; saturates instead of overflowing.</summary>
    public static decimal Amount(long microUsd, decimal rate) => Scaled(Math.Max(0, microUsd), rate);

    /// <summary>
    /// A live micro-USD-per-second value in the display currency per second. The <see cref="double"/> enters as the
    /// decimal of its shortest round-trip text, so both platforms start from the same digits.
    /// </summary>
    public static decimal Rate(double microUsdPerSecond, decimal rate)
    {
        if (!double.IsFinite(microUsdPerSecond) || microUsdPerSecond <= 0)
        {
            return 0;
        }

        var text = microUsdPerSecond.ToString("R", CultureInfo.InvariantCulture);
        return decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? Scaled(value, rate)
            : decimal.MaxValue;
    }

    public static FormattedMoney Format(decimal value, Currency currency, string language, MoneyForm form)
    {
        ArgumentNullException.ThrowIfNull(currency);
        var number = Number(value, currency.Digits, form);
        var symbol = currency.SymbolFor(language);
        var text = form == MoneyForm.Amount ? WithSymbol(symbol, number) : number + " " + symbol + "/s";
        return new FormattedMoney(number, text, symbol);
    }

    /// <summary>
    /// The symbol in front of a number: a no-break space after a symbol that ends in a letter (<c>CHF 0.42</c>), and the
    /// <c>&lt;</c> of the smallest value before the symbol (<c>&lt;$0.000001</c>).
    /// </summary>
    public static string WithSymbol(string symbol, string number)
    {
        ArgumentNullException.ThrowIfNull(symbol);
        ArgumentNullException.ThrowIfNull(number);
        var separator = Rune.DecodeLastFromUtf16(symbol, out var last, out _) == OperationStatus.Done && Rune.IsLetter(last)
            ? NoBreakSpace
            : string.Empty;
        return number.StartsWith('<') ? "<" + symbol + separator + number[1..] : symbol + separator + number;
    }

    /// <summary>The digits of a money value, with <paramref name="digits"/> decimals for amounts.</summary>
    public static string Number(decimal value, int digits, MoneyForm form)
    {
        var d = Math.Clamp(digits, 0, MaxScale);
        var v = value < 0 ? 0 : value;
        if (v == 0)
        {
            return form == MoneyForm.Rate || d == 0 ? "0" : "0." + new string('0', d);
        }

        if (v < Tiny)
        {
            return BelowSmallest;
        }

        if (v < 1)
        {
            var (w, scale) = RoundSignificant(v, 2);
            if (w < 1)
            {
                return Trim(Fixed(w, scale), d);
            }
        }

        if (form == MoneyForm.Rate && v < 100)
        {
            var (w, scale) = RoundSignificant(v, 3);
            if (w < 100)
            {
                return Trim(Fixed(w, scale), d);
            }
        }

        if (v < Million)
        {
            var scale = form == MoneyForm.Rate ? 0 : d;
            var w = Round(v, scale);
            if (w < Million)
            {
                return Group(Fixed(w, scale));
            }
        }

        return Compact(v);
    }

    /// <summary>
    /// The rate in <c>rates.status</c> (DESIGN 9): at least <paramref name="digits"/> significant digits, half up, integers
    /// grouped and never fewer decimals than significance needs (<c>32.55</c>, <c>158.1</c>, <c>0.8903</c>, <c>25,842</c>).
    /// </summary>
    public static string Significant(decimal value, int digits = 4)
    {
        if (value <= 0)
        {
            return "0";
        }

        var scale = Math.Clamp(digits - 1 - Adjusted(value), 0, MaxScale);
        var rounded = Round(value, scale);
        if (Adjusted(rounded) > Adjusted(value) && scale > 0)
        {
            // Rounding carried into the next power of ten (9.99999 → 10.000): one decimal less.
            scale--;
            rounded = Round(value, scale);
        }

        return Group(Fixed(rounded, scale));
    }

    /// <summary><c>cost_usd</c> (DESIGN 9 Usage history): exactly 6 decimals from micro-USD.</summary>
    public static string CsvUsd(long microUsd) => Fixed(Math.Max(0, microUsd) / Million, 6);

    /// <summary><c>cost_&lt;code&gt;</c>: the amount in the display currency with the currency's digits + 2 decimals, half up.</summary>
    public static string Csv(long microUsd, decimal rate, int digits)
    {
        var scale = Math.Clamp(digits + 2, 0, MaxScale);
        return Fixed(Round(Math.Max(0, Amount(microUsd, rate)), scale), scale);
    }

    internal static decimal Round(decimal value, int scale) => Math.Round(value, scale, MidpointRounding.AwayFromZero);

    /// <summary>Floor of log10 of a positive value.</summary>
    internal static int Adjusted(decimal value)
    {
        var exponent = 0;
        var power = 1m;
        while (power <= LargestPower && value >= power * 10)
        {
            power *= 10;
            exponent++;
        }

        while (value < power && exponent > -MaxScale)
        {
            power /= 10;
            exponent--;
        }

        return exponent;
    }

    /// <summary>Rounded half up to <paramref name="digits"/> significant digits, at most 6 decimals; with the decimals it keeps.</summary>
    internal static (decimal Value, int Scale) RoundSignificant(decimal value, int digits)
    {
        var scale = Math.Clamp(-Math.Max(Adjusted(value) - digits + 1, -6), 0, MaxScale);
        return (Round(value, scale), scale);
    }

    /// <summary>The plain digits of a value already rounded to <paramref name="scale"/> decimals, with exactly that many decimals.</summary>
    internal static string Fixed(decimal value, int scale) =>
        Math.Abs(value).ToString("F" + scale.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);

    /// <summary>Drops trailing fractional zeros beyond <paramref name="digits"/> decimals, then pads to <paramref name="digits"/> decimals.</summary>
    internal static string Trim(string text, int digits)
    {
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        var whole = dot < 0 ? text : text[..dot];
        var fraction = dot < 0 ? string.Empty : text[(dot + 1)..];
        var length = fraction.Length;
        while (length > digits && fraction[length - 1] == '0')
        {
            length--;
        }

        fraction = fraction[..length].PadRight(digits, '0');
        return fraction.Length == 0 ? whole : whole + "." + fraction;
    }

    /// <summary>Thousands separators in the whole part.</summary>
    internal static string Group(string text)
    {
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        var whole = dot < 0 ? text : text[..dot];
        var rest = dot < 0 ? string.Empty : text[dot..];
        var builder = new StringBuilder(text.Length + whole.Length / 3);
        var lead = whole.Length % 3 == 0 ? 3 : whole.Length % 3;
        builder.Append(whole, 0, Math.Min(lead, whole.Length));
        for (var i = lead; i < whole.Length; i += 3)
        {
            builder.Append(',').Append(whole, i, 3);
        }

        return builder.Append(rest).ToString();
    }

    /// <summary>METRICS 7 for values of at least one million: <c>1.28M</c>, <c>12.8M</c>, <c>128M</c>, <c>1.28B</c>, …</summary>
    internal static string Compact(decimal value)
    {
        foreach (var (unit, scale) in new[] { ("M", 1_000_000m), ("B", 1_000_000_000m) })
        {
            var x = value / scale;
            foreach (var (limit, places) in new[] { (10m, 2), (100m, 1), (1000m, 0) })
            {
                var r = Round(x, places);
                if (x < limit && r < limit)
                {
                    return Fixed(r, places) + unit;
                }
            }

            if (unit == "B")
            {
                return Group(Fixed(Round(x, 0), 0)) + "B";
            }
        }

        return Fixed(value, 0);
    }

    private static decimal Scaled(decimal value, decimal rate)
    {
        try
        {
            return value * rate / Million;
        }
        catch (OverflowException)
        {
            return decimal.MaxValue;
        }
    }
}
