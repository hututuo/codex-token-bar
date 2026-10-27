using System.Globalization;

namespace AgentSpeed.Core;

/// <summary>Compact number formatting shared by every surface (METRICS section 7).</summary>
public static class SpeedFormat
{
    private static readonly (double Scale, string Unit)[] Units = [(1e3, "k"), (1e6, "M"), (1e9, "B")];

    public static string Speed(double value)
    {
        if (!double.IsFinite(value) || value <= 0)
        {
            return "0";
        }

        if (value < 10)
        {
            var rounded = Math.Round(value, 1, MidpointRounding.AwayFromZero);
            return rounded >= 10 ? "10" : Fixed(rounded, 1);
        }

        if (value < 1000)
        {
            var rounded = Math.Round(value, MidpointRounding.AwayFromZero);
            return rounded >= 1000 ? "1.00k" : ((long)rounded).ToString(CultureInfo.InvariantCulture);
        }

        return Compact(value);
    }

    public static string Tokens(long value)
    {
        if (value <= 0)
        {
            return "0";
        }

        return value < 1000 ? value.ToString(CultureInfo.InvariantCulture) : Compact(value);
    }

    // Three significant digits; a value that rounds up to the next unit uses it (999 700 → 1.00M).
    private static string Compact(double value)
    {
        for (var i = 0; i < Units.Length; i++)
        {
            var (scale, unit) = Units[i];
            var scaled = value / scale;
            if (Round(scaled, 2) < 10)
            {
                return Fixed(scaled, 2) + unit;
            }

            if (Round(scaled, 1) < 100)
            {
                return Fixed(scaled, 1) + unit;
            }

            if (Round(scaled, 0) < 1000 || i == Units.Length - 1)
            {
                return Fixed(scaled, 0) + unit;
            }
        }

        return Fixed(value, 0);
    }

    private static double Round(double value, int digits) =>
        Math.Round(value, digits, MidpointRounding.AwayFromZero);

    private static string Fixed(double value, int digits) =>
        Round(value, digits).ToString("F" + digits.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
}
