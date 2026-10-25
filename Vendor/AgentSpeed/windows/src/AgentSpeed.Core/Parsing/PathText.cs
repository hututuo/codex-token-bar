namespace AgentSpeed.Core.Parsing;

/// <summary>Path helpers that accept both Windows (<c>\</c>) and POSIX (<c>/</c>) separators.</summary>
internal static class PathText
{
    private static readonly char[] Separators = ['/', '\\'];

    /// <summary>Last non-empty component, e.g. <c>C:\Users\me\proj\</c> → <c>proj</c>.</summary>
    public static string Basename(string path)
    {
        var trimmed = path.AsSpan().TrimEnd(Separators);
        if (trimmed.IsEmpty)
        {
            return string.Empty;
        }

        var index = trimmed.LastIndexOfAny(Separators);
        return index < 0 ? trimmed.ToString() : trimmed[(index + 1)..].ToString();
    }

    /// <summary>True when any directory component (not the file name) equals <paramref name="name"/>.</summary>
    public static bool HasDirectoryComponent(string path, string name)
    {
        var span = path.AsSpan();
        var last = span.LastIndexOfAny(Separators);
        if (last < 0)
        {
            return false;
        }

        foreach (var range in span[..last].SplitAny(Separators))
        {
            if (span[range].SequenceEqual(name))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>Number of non-empty components in a relative path.</summary>
    public static int ComponentCount(ReadOnlySpan<char> relativePath)
    {
        var count = 0;
        foreach (var range in relativePath.SplitAny(Separators))
        {
            if (!relativePath[range].IsEmpty)
            {
                count++;
            }
        }

        return count;
    }
}
