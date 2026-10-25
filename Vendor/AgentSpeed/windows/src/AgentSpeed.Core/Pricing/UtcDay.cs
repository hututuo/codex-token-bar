namespace AgentSpeed.Core.Pricing;

/// <summary>UTC calendar facts of an instant, from integer arithmetic (METRICS 9.1 periods and off-peak hours).</summary>
internal readonly record struct UtcDay
{
    public const long MsPerDay = 86_400_000;

    public UtcDay(long ms)
    {
        var days = ms / MsPerDay;
        var rest = ms % MsPerDay;
        if (rest < 0)
        {
            days--;
            rest += MsPerDay;
        }

        DaysSinceEpoch = days;
        MsOfDay = rest;
    }

    public long DaysSinceEpoch { get; }

    public long MsOfDay { get; }

    public int MinuteOfDay => (int)(MsOfDay / 60_000);

    /// <summary>ISO weekday, 1 = Monday; 1970-01-01 was a Thursday.</summary>
    public int IsoWeekday
    {
        get
        {
            var offset = (int)((DaysSinceEpoch + 3) % 7);
            return (offset < 0 ? offset + 7 : offset) + 1;
        }
    }

    /// <summary><c>YYYY-MM-DD</c> (proleptic Gregorian, civil-from-days).</summary>
    public string Label
    {
        get
        {
            var z = DaysSinceEpoch + 719_468;
            var era = (z >= 0 ? z : z - 146_096) / 146_097;
            var doe = z - era * 146_097;
            var yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
            var doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            var mp = (5 * doy + 2) / 153;
            var day = doy - (153 * mp + 2) / 5 + 1;
            var month = mp < 10 ? mp + 3 : mp - 9;
            var year = yoe + era * 400 + (month <= 2 ? 1 : 0);
            return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{year:D4}-{month:D2}-{day:D2}");
        }
    }

    /// <summary>Unix ms of <c>YYYY-MM-DD</c> (00:00 UTC) or <c>YYYY-MM-DDTHH:MMZ</c>; null for any other text or an impossible date.</summary>
    public static long? InstantMs(string? text)
    {
        if (text is null || (text.Length != 10 && text.Length != 17) || text[4] != '-' || text[7] != '-')
        {
            return null;
        }

        if (Number(text, 0, 4) is not { } year || Number(text, 5, 2) is not { } month || Number(text, 8, 2) is not { } day
            || month is < 1 or > 12 || year < 1)
        {
            return null;
        }

        var leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
        long[] lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (day < 1 || day > lengths[month - 1])
        {
            return null;
        }

        long minutes = 0;
        if (text.Length == 17)
        {
            if (text[10] != 'T' || text[13] != ':' || text[16] != 'Z'
                || Number(text, 11, 2) is not { } hour || Number(text, 14, 2) is not { } minute || hour >= 24 || minute >= 60)
            {
                return null;
            }

            minutes = hour * 60 + minute;
        }

        var y = month <= 2 ? year - 1 : year;
        var era = (y >= 0 ? y : y - 399) / 400;
        var yoe = y - era * 400;
        var mp = month > 2 ? month - 3 : month + 9;
        var doy = (153 * mp + 2) / 5 + day - 1;
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        var days = era * 146_097 + doe - 719_468;
        return days * MsPerDay + minutes * 60_000;
    }

    /// <summary><c>YYYY-MM-DD</c> with ASCII digits only.</summary>
    public static bool IsDateText(string? text)
    {
        if (text is null || text.Length != 10)
        {
            return false;
        }

        for (var i = 0; i < 10; i++)
        {
            if (i is 4 or 7 ? text[i] != '-' : text[i] is < '0' or > '9')
            {
                return false;
            }
        }

        return true;
    }

    private static long? Number(string text, int start, int length)
    {
        long value = 0;
        for (var i = start; i < start + length; i++)
        {
            var c = text[i];
            if (c is < '0' or > '9')
            {
                return null;
            }

            value = value * 10 + (c - '0');
        }

        return value;
    }
}
