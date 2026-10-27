using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace AgentSpeed.Core.Reporting;

public enum ReportUsernameCharset
{
    Unicode,
    Ascii,
}

/// <summary>A service's <c>username</c> rules (REPORTING 3.2, 4.3), clamped to the protocol's ranges.</summary>
public sealed record ReportUsernameRules
{
    public ReportUsernameRules(int minLength = 2, int maxLength = 32, ReportUsernameCharset charset = ReportUsernameCharset.Unicode, bool spaces = true)
    {
        MinLength = Math.Clamp(minLength, 1, 12);
        MaxLength = Math.Clamp(maxLength, 12, 32);
        Charset = charset;
        Spaces = spaces;
    }

    /// <summary>The protocol grammar with the default lengths: the rules before a service's document is known.</summary>
    public static ReportUsernameRules Standard { get; } = new();

    public int MinLength { get; }

    public int MaxLength { get; }

    public ReportUsernameCharset Charset { get; }

    public bool Spaces { get; }
}

/// <summary>The reasons of REPORTING 4.3, in check order.</summary>
public enum ReportUsernameProblem
{
    Characters,
    Length,
    Spaces,
    Start,
}

/// <summary>
/// Username grammar, default names and comparison keys of REPORTING 4.3 and DESIGN 11, following
/// <c>spec/tools/report_reference.py</c> code point by code point.
/// </summary>
public static class ReportUsername
{
    public const string RandomPrefix = "racer-";
    private const int MaxMarksInARow = 4;
    private const string RandomAlphabet = "23456789abcdefghjkmnpqrstuvwxyz";
    private static readonly int[] Apostrophes = ['\'', '\u2018', '\u2019', '\u02BC', '`'];

    /// <summary>Full case foldings that differ from the simple lower-case mapping (Unicode CaseFolding.txt, as Python applies it).</summary>
    private const string FoldingTable =
        "B5:3BC;DF:73 73;130:69 307;149:2BC 6E;17F:73;1F0:6A 30C;345:3B9;390:3B9 308 301;3B0:3C5 308 301;3C2:3C3;3D0:3B2;3D1:3B8;" +
        "3D5:3C6;3D6:3C0;3F0:3BA;3F1:3C1;3F5:3B5;587:565 582;1C80:432;1C81:434;1C82:43E;1C83:441;1C84:442;1C85:442;1C86:44A;" +
        "1C87:463;1C88:A64B;1E96:68 331;1E97:74 308;1E98:77 30A;1E99:79 30A;1E9A:61 2BE;1E9B:1E61;1E9E:73 73;1F50:3C5 313;" +
        "1F52:3C5 313 300;1F54:3C5 313 301;1F56:3C5 313 342;1F80:1F00 3B9;1F81:1F01 3B9;1F82:1F02 3B9;1F83:1F03 3B9;1F84:1F04 3B9;" +
        "1F85:1F05 3B9;1F86:1F06 3B9;1F87:1F07 3B9;1F88:1F00 3B9;1F89:1F01 3B9;1F8A:1F02 3B9;1F8B:1F03 3B9;1F8C:1F04 3B9;" +
        "1F8D:1F05 3B9;1F8E:1F06 3B9;1F8F:1F07 3B9;1F90:1F20 3B9;1F91:1F21 3B9;1F92:1F22 3B9;1F93:1F23 3B9;1F94:1F24 3B9;" +
        "1F95:1F25 3B9;1F96:1F26 3B9;1F97:1F27 3B9;1F98:1F20 3B9;1F99:1F21 3B9;1F9A:1F22 3B9;1F9B:1F23 3B9;1F9C:1F24 3B9;" +
        "1F9D:1F25 3B9;1F9E:1F26 3B9;1F9F:1F27 3B9;1FA0:1F60 3B9;1FA1:1F61 3B9;1FA2:1F62 3B9;1FA3:1F63 3B9;1FA4:1F64 3B9;" +
        "1FA5:1F65 3B9;1FA6:1F66 3B9;1FA7:1F67 3B9;1FA8:1F60 3B9;1FA9:1F61 3B9;1FAA:1F62 3B9;1FAB:1F63 3B9;1FAC:1F64 3B9;" +
        "1FAD:1F65 3B9;1FAE:1F66 3B9;1FAF:1F67 3B9;1FB2:1F70 3B9;1FB3:3B1 3B9;1FB4:3AC 3B9;1FB6:3B1 342;1FB7:3B1 342 3B9;" +
        "1FBC:3B1 3B9;1FBE:3B9;1FC2:1F74 3B9;1FC3:3B7 3B9;1FC4:3AE 3B9;1FC6:3B7 342;1FC7:3B7 342 3B9;1FCC:3B7 3B9;" +
        "1FD2:3B9 308 300;1FD3:3B9 308 301;1FD6:3B9 342;1FD7:3B9 308 342;1FE2:3C5 308 300;1FE3:3C5 308 301;1FE4:3C1 313;" +
        "1FE6:3C5 342;1FE7:3C5 308 342;1FF2:1F7C 3B9;1FF3:3C9 3B9;1FF4:3CE 3B9;1FF6:3C9 342;1FF7:3C9 342 3B9;1FFC:3C9 3B9;" +
        "FB00:66 66;FB01:66 69;FB02:66 6C;FB03:66 66 69;FB04:66 66 6C;FB05:73 74;FB06:73 74;FB13:574 576;FB14:574 565;" +
        "FB15:574 56B;FB16:57E 576;FB17:574 56D";

    private static readonly Lazy<Dictionary<int, string>> Foldings = new(ParseFoldings);

    /// <summary>NFKC, which the client applies before validating and sending (REPORTING 4.3); ill-formed text stays as it is.</summary>
    public static string Normalized(string text)
    {
        try
        {
            return text.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            return text;
        }
    }

    /// <summary>The first failing check of REPORTING 4.3, or null when the name is valid for <paramref name="rules"/>.</summary>
    public static ReportUsernameProblem? Validate(string name, ReportUsernameRules rules)
    {
        string normalized;
        try
        {
            normalized = name.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            return ReportUsernameProblem.Characters;
        }

        if (!string.Equals(normalized, name, StringComparison.Ordinal))
        {
            return ReportUsernameProblem.Characters;
        }

        var runes = name.EnumerateRunes().ToArray();
        if (runes.Length < rules.MinLength || runes.Length > rules.MaxLength)
        {
            return ReportUsernameProblem.Length;
        }

        var marks = 0;
        foreach (var rune in runes)
        {
            if (IsSpace(rune) && rune.Value != ' ')
            {
                return ReportUsernameProblem.Spaces;
            }

            if (!IsAllowed(rune, rules))
            {
                return rune.Value == ' ' ? ReportUsernameProblem.Spaces : ReportUsernameProblem.Characters;
            }

            marks = IsMark(rune) ? marks + 1 : 0;
            if (marks > MaxMarksInARow)
            {
                return ReportUsernameProblem.Characters;
            }
        }

        if (!IsLetterOrNumber(runes[0], rules))
        {
            return ReportUsernameProblem.Start;
        }

        return name.EndsWith(' ') || name.Contains("  ", StringComparison.Ordinal) ? ReportUsernameProblem.Spaces : null;
    }

    /// <summary>The computer name fitted to <paramref name="rules"/> (DESIGN 11 <c>fit</c>), or null when nothing valid remains.</summary>
    public static string? Fit(string computerName, ReportUsernameRules rules)
    {
        var text = Normalized(computerName).EnumerateRunes().Where(r => !Apostrophes.Contains(r.Value)).ToList();
        if (rules.Charset == ReportUsernameCharset.Ascii)
        {
            string decomposed;
            try
            {
                decomposed = Join(text).Normalize(NormalizationForm.FormKD);
            }
            catch (ArgumentException)
            {
                return null;
            }

            text = decomposed.EnumerateRunes().Where(r => !IsMark(r)).ToList();
        }

        var separator = new Rune(rules.Spaces ? ' ' : '-');
        text = text.Select(r => !IsSpace(r) && IsAllowed(r, rules) ? r : separator).ToList();
        text = CollapseSeparators(text);
        var start = text.FindIndex(r => IsLetterOrNumber(r, rules));
        text = start < 0 ? [] : text[start..];
        if (text.Count > rules.MaxLength)
        {
            text = text[..rules.MaxLength];
        }

        while (text.Count > 0 && text[^1].Value is ' ' or '-' or '_' or '.')
        {
            text.RemoveAt(text.Count - 1);
        }

        var name = Join(text);
        return Validate(name, rules) is null ? name : null;
    }

    /// <summary><c>racer-</c> and 6 characters from the system's cryptographic random generator (DESIGN 11).</summary>
    public static string Random()
    {
        Span<char> suffix = stackalloc char[6];
        for (var i = 0; i < suffix.Length; i++)
        {
            suffix[i] = RandomAlphabet[RandomNumberGenerator.GetInt32(RandomAlphabet.Length)];
        }

        return RandomPrefix + new string(suffix);
    }

    /// <summary><c>NFKC(casefold(NFKC(name)))</c> with full Unicode case folding (REPORTING 4.3).</summary>
    public static string ComparisonKey(string name) => Normalized(CaseFolded(Normalized(name)));

    /// <summary>Whether two usernames are the same name for uniqueness (REPORTING 4.3).</summary>
    public static bool IsSameName(string a, string b) => string.Equals(ComparisonKey(a), ComparisonKey(b), StringComparison.Ordinal);

    /// <summary><c>str.isspace()</c>: the ASCII separators and Unicode White_Space.</summary>
    internal static bool IsSpace(Rune rune) =>
        rune.Value is (>= 0x09 and <= 0x0D) or (>= 0x1C and <= 0x20) || (rune.Value >= 0x80 && Rune.IsWhiteSpace(rune));

    internal static bool IsSpace(char c) => IsSpace(new Rune(c));

    private static bool IsAsciiAlphanumeric(Rune rune) => rune.IsAscii && char.IsAsciiLetterOrDigit((char)rune.Value);

    private static bool IsMark(Rune rune) => Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark
        or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    private static bool IsLetterOrNumberCategory(Rune rune) => Rune.GetUnicodeCategory(rune) is UnicodeCategory.UppercaseLetter
        or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
        or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber
        or UnicodeCategory.OtherNumber;

    private static bool IsLetterOrNumber(Rune rune, ReportUsernameRules rules) =>
        rules.Charset == ReportUsernameCharset.Ascii ? IsAsciiAlphanumeric(rune) : IsLetterOrNumberCategory(rune);

    private static bool IsAllowed(Rune rune, ReportUsernameRules rules)
    {
        if (rune.Value == ' ')
        {
            return rules.Spaces;
        }

        if (rune.Value is '_' or '-' or '.')
        {
            return true;
        }

        return rules.Charset == ReportUsernameCharset.Ascii ? IsAsciiAlphanumeric(rune) : IsLetterOrNumberCategory(rune) || IsMark(rune);
    }

    /// <summary>A run of spaces and hyphens becomes one <c>-</c> when it contains one, else one space.</summary>
    private static List<Rune> CollapseSeparators(List<Rune> text)
    {
        var output = new List<Rune>(text.Count);
        var index = 0;
        while (index < text.Count)
        {
            if (text[index].Value is not (' ' or '-'))
            {
                output.Add(text[index]);
                index++;
                continue;
            }

            var hyphen = false;
            while (index < text.Count && text[index].Value is ' ' or '-')
            {
                hyphen |= text[index].Value == '-';
                index++;
            }

            output.Add(new Rune(hyphen ? '-' : ' '));
        }

        return output;
    }

    /// <summary><c>str.casefold()</c>: the full case foldings of the table, Cherokee to upper case, else the simple lower case.</summary>
    internal static string CaseFolded(string text)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            var value = rune.Value;
            if (value is >= 0x13A0 and <= 0x13F5)
            {
                builder.Append(rune.ToString());
            }
            else if (value is >= 0x13F8 and <= 0x13FD)
            {
                builder.Append(new Rune(value - 8).ToString());
            }
            else if (value is >= 0xAB70 and <= 0xABBF)
            {
                builder.Append(new Rune(value - 0xAB70 + 0x13A0).ToString());
            }
            else if (Foldings.Value.TryGetValue(value, out var folded))
            {
                builder.Append(folded);
            }
            else
            {
                builder.Append(Rune.ToLowerInvariant(rune).ToString());
            }
        }

        return builder.ToString();
    }

    private static Dictionary<int, string> ParseFoldings()
    {
        var table = new Dictionary<int, string>();
        foreach (var entry in FoldingTable.Split(';'))
        {
            var colon = entry.IndexOf(':', StringComparison.Ordinal);
            var key = int.Parse(entry.AsSpan(0, colon), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var value = new StringBuilder();
            foreach (var part in entry[(colon + 1)..].Split(' '))
            {
                value.Append(new Rune(int.Parse(part, NumberStyles.HexNumber, CultureInfo.InvariantCulture)).ToString());
            }

            table[key] = value.ToString();
        }

        return table;
    }

    private static string Join(IEnumerable<Rune> runes)
    {
        var builder = new StringBuilder();
        foreach (var rune in runes)
        {
            builder.Append(rune.ToString());
        }

        return builder.ToString();
    }
}
