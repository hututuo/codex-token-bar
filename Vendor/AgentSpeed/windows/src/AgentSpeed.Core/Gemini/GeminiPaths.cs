using System.Text;

namespace AgentSpeed.Core.Gemini;

/// <summary>Gemini CLI session layout (METRICS 4.6): <c>&lt;projectDir&gt;/chats/[&lt;dir&gt;/]&lt;file&gt;</c>, either separator.</summary>
internal static class GeminiPaths
{
    public const string ChatsFolder = "chats";

    private static readonly char[] Separators = ['/', '\\'];

    /// <summary>Every code point outside <c>[A-Za-z0-9_-]</c> becomes <c>_</c> (one per code point, as Python's <c>re</c>).</summary>
    public static string Sanitize(string id)
    {
        var i = 0;
        while (i < id.Length && IsKept(id[i]))
        {
            i++;
        }

        if (i == id.Length)
        {
            return id;
        }

        var builder = new StringBuilder(id.Length);
        builder.Append(id, 0, i);
        for (; i < id.Length; i++)
        {
            var c = id[i];
            if (IsKept(c))
            {
                builder.Append(c);
                continue;
            }

            if (char.IsHighSurrogate(c) && i + 1 < id.Length && char.IsLowSurrogate(id[i + 1]))
            {
                i++;
            }

            builder.Append('_');
        }

        return builder.ToString();
    }

    /// <summary>The file sits directly inside a directory named <c>chats</c>.</summary>
    public static bool IsMainSessionPath(string path)
    {
        var parts = Components(path);
        return parts.Length >= 2 && parts[^2] == ChatsFolder;
    }

    /// <summary>The <c>&lt;dir&gt;</c> of <c>chats/&lt;dir&gt;/&lt;file&gt;</c> (a sub-agent's parent session folder), else null.</summary>
    public static string? ParentDirectoryOf(string path)
    {
        var parts = Components(path);
        return parts.Length >= 3 && parts[^3] == ChatsFolder ? parts[^2] : null;
    }

    /// <summary>The project folder that holds the <c>chats</c> folder of a session file, else null.</summary>
    public static string? ProjectDirectoryOf(string path)
    {
        var span = path.AsSpan();
        var file = span.LastIndexOfAny(Separators);
        if (file < 0)
        {
            return null;
        }

        var parent = span[..file];
        var cut = parent.LastIndexOfAny(Separators);
        if (cut < 0)
        {
            return null;
        }

        if (!parent[(cut + 1)..].SequenceEqual(ChatsFolder))
        {
            var grandparent = parent[..cut];
            cut = grandparent.LastIndexOfAny(Separators);
            if (cut < 0 || !grandparent[(cut + 1)..].SequenceEqual(ChatsFolder))
            {
                return null;
            }
        }

        return cut == 0 ? null : path[..cut];
    }

    private static bool IsKept(char c) => char.IsAsciiLetterOrDigit(c) || c is '_' or '-';

    private static string[] Components(string path) => path.Split(Separators, StringSplitOptions.RemoveEmptyEntries);
}
