namespace AgentSpeed.Core.Parsing;

/// <summary>Allocation-free RFC 3339 / ISO 8601 timestamp parsing to Unix milliseconds (METRICS 3.1).</summary>
internal static class Rfc3339
{
    /// <summary>The longest timestamp (METRICS 3.1).</summary>
    public const int MaxLength = 64;

    public static bool TryParseUnixMs(ReadOnlySpan<byte> text, out long unixMs)
    {
        unixMs = 0;
        if (text.Length < 20 || text.Length > MaxLength
            || !TryDigits(text, 0, 4, out var year) || text[4] != '-'
            || !TryDigits(text, 5, 2, out var month) || text[7] != '-'
            || !TryDigits(text, 8, 2, out var day)
            || text[10] is not ((byte)'T' or (byte)'t' or (byte)' ')
            || !TryDigits(text, 11, 2, out var hour) || text[13] != ':'
            || !TryDigits(text, 14, 2, out var minute) || text[16] != ':'
            || !TryDigits(text, 17, 2, out var second))
        {
            return false;
        }

        var i = 19;
        var millis = 0;
        if (text[i] == '.')
        {
            i++;
            var digits = 0;
            while (i < text.Length && IsDigit(text[i]))
            {
                if (digits < 3)
                {
                    millis = millis * 10 + (text[i] - '0');
                }

                digits++;
                i++;
            }

            if (digits == 0)
            {
                return false;
            }

            for (var d = Math.Min(digits, 3); d < 3; d++)
            {
                millis *= 10;
            }
        }

        if (i >= text.Length)
        {
            return false;
        }

        int offsetMinutes;
        var zone = text[i];
        if (zone is (byte)'Z' or (byte)'z')
        {
            offsetMinutes = 0;
            i++;
        }
        else if (zone is (byte)'+' or (byte)'-')
        {
            i++;
            if (!TryDigits(text, i, 2, out var offsetHours))
            {
                return false;
            }

            i += 2;
            if (i < text.Length && text[i] == ':')
            {
                i++;
            }

            if (!TryDigits(text, i, 2, out var offsetMins))
            {
                return false;
            }

            i += 2;

            if (offsetHours > 23 || offsetMins > 59)
            {
                return false;
            }

            offsetMinutes = (offsetHours * 60 + offsetMins) * (zone == '-' ? -1 : 1);
        }
        else
        {
            return false;
        }

        if (i != text.Length
            || month is < 1 or > 12
            || day < 1 || day > DaysInMonth(year, month)
            || hour > 23 || minute > 59 || second > 59)
        {
            return false;
        }

        var days = DaysFromCivil(year, month, day);
        var seconds = days * 86_400L + hour * 3600L + minute * 60L + second - offsetMinutes * 60L;
        unixMs = seconds * 1000 + millis;
        return true;
    }

    private static bool IsDigit(byte b) => (uint)(b - '0') <= 9;

    private static bool TryDigits(ReadOnlySpan<byte> text, int start, int count, out int value)
    {
        value = 0;
        if (start + count > text.Length)
        {
            return false;
        }

        for (var i = start; i < start + count; i++)
        {
            if (!IsDigit(text[i]))
            {
                return false;
            }

            value = value * 10 + (text[i] - '0');
        }

        return true;
    }

    private static int DaysInMonth(int year, int month) => month switch
    {
        2 => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28,
        4 or 6 or 9 or 11 => 30,
        _ => 31,
    };

    // Howard Hinnant's days_from_civil.
    private static long DaysFromCivil(int year, int month, int day)
    {
        long y = month <= 2 ? year - 1 : year;
        var era = (y >= 0 ? y : y - 399) / 400;
        var yoe = y - era * 400;
        var mp = (month + 9) % 12;
        var doy = (153 * mp + 2) / 5 + day - 1;
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }
}
