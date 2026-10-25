using System.Globalization;

namespace AgentSpeed.Core.Traffic;

/// <summary>
/// Byte formatting shared by every surface (METRICS 10.11): decimal units, three significant digits, a value that rounds
/// to 1000 moves to the next unit, half-up rounding on the decimal value, a no-break space between number and unit.
/// </summary>
public static class TrafficFormat
{
    public const char NoBreakSpace = ' ';

    /// <summary>The number and the unit separately, for fixed cells (DESIGN 10, Formatting).</summary>
    public readonly record struct Parts(string Number, string Unit)
    {
        public string Text => Number + NoBreakSpace + Unit;

        public override string ToString() => Text;
    }

    public static IReadOnlyList<string> RateUnits { get; } = ["B/s", "KB/s", "MB/s", "GB/s"];

    public static IReadOnlyList<string> BitRateUnits { get; } = ["b/s", "Kb/s", "Mb/s", "Gb/s"];

    public static IReadOnlyList<string> TotalUnits { get; } = ["B", "KB", "MB", "GB", "TB"];

    private static readonly decimal TwoDecimalsBelow = 9.995m;
    private static readonly decimal OneDecimalBelow = 99.95m;
    private static readonly decimal MaxValue = 1e27m;

    public static Parts RateParts(double bytesPerSecond, bool bits = false) =>
        bits ? Format(bytesPerSecond * 8, BitRateUnits) : Format(bytesPerSecond, RateUnits);

    public static Parts TotalParts(double bytes) => Format(bytes, TotalUnits);

    public static string Rate(double bytesPerSecond, bool bits = false) => RateParts(bytesPerSecond, bits).Text;

    public static string Total(double bytes) => TotalParts(bytes).Text;

    public static string Total(long bytes) => Total((double)bytes);

    /// <summary>
    /// Works on the shortest decimal text of the value (as Python's <c>Decimal(str(x))</c>), so <c>9.995</c> rounds up as
    /// written rather than as its binary neighbour.
    /// </summary>
    private static Parts Format(double value, IReadOnlyList<string> units)
    {
        var x = ToDecimal(value);
        var unit = 0;
        while (true)
        {
            decimal shown;
            int digits;
            if (unit == 0)
            {
                shown = Math.Round(x, 0, MidpointRounding.AwayFromZero);
                digits = 0;
            }
            else if (x < TwoDecimalsBelow)
            {
                shown = Math.Round(x, 2, MidpointRounding.AwayFromZero);
                digits = 2;
            }
            else if (x < OneDecimalBelow)
            {
                shown = Math.Round(x, 1, MidpointRounding.AwayFromZero);
                digits = 1;
            }
            else
            {
                shown = Math.Round(x, 0, MidpointRounding.AwayFromZero);
                digits = 0;
            }

            if (shown < 1000 || unit == units.Count - 1)
            {
                var text = shown.ToString(digits switch { 2 => "0.00", 1 => "0.0", _ => "0" }, CultureInfo.InvariantCulture);
                return new Parts(text, units[unit]);
            }

            x /= 1000;
            unit++;
        }
    }

    private static decimal ToDecimal(double value)
    {
        if (!double.IsFinite(value) || value <= 0)
        {
            return 0;
        }

        if (value >= (double)MaxValue)
        {
            return MaxValue;
        }

        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : (decimal)value;
    }
}
