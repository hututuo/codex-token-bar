using System.IO.Enumeration;

namespace AgentSpeed.Core.IO;

internal readonly record struct DiscoveredFile(string Path, long Length, DateTime LastWriteUtc);

/// <summary>Which file names a root's transcripts have (METRICS 2).</summary>
internal enum TranscriptNaming
{
    /// <summary><c>*.jsonl</c> (Claude).</summary>
    Jsonl,

    /// <summary><c>session.v&lt;N&gt;.jsonl.zstd</c> or <c>session.v&lt;N&gt;.jsonl</c> (DeepSeek Harness).</summary>
    DshSession,

    /// <summary><c>*.jsonl</c> or compressed <c>*.jsonl.zst</c> (Codex, METRICS 5.3).</summary>
    CodexRollout,

    /// <summary><c>*.jsonl</c> or legacy <c>*.json</c> at fixed depths (Gemini CLI, METRICS 4.6).</summary>
    GeminiSession,

    /// <summary><c>opencode.db</c> and its WAL in one folder (OpenCode, METRICS 5.2); not enumerated.</summary>
    OpenCodeDatabase,

    /// <summary><c>*.jsonl</c> at least one folder below the root, nothing starting with <c>.</c> (omp, METRICS 4.7).</summary>
    OmpSession,

    /// <summary><c>&lt;uuid&gt;.db</c> directly in a <c>conversations</c> folder (Antigravity, METRICS 4.8).</summary>
    AntigravityDatabase,

    /// <summary><c>&lt;slug&gt;/*.jsonl</c> and <c>&lt;slug&gt;/&lt;dir&gt;/subagents/*.jsonl</c> (WorkBuddy, METRICS 4.9).</summary>
    WorkBuddySession,
    ZCodeDatabase,
    KimiSession,
    GrokBuildSession,
}

/// <summary>Recursive transcript enumeration that never follows reparse points or symlinks (METRICS 2).</summary>
internal static class TranscriptDiscovery
{
    /// <summary>Directories are listed down to this many levels below the root, so files sit at most one deeper.</summary>
    public const int MaxDepth = 6;

    public const int MaxFilesPerRoot = 20_000;

    private const int MaxScannedEntries = 200_000;

    public static bool IsTranscriptName(ReadOnlySpan<char> fileName, TranscriptNaming naming = TranscriptNaming.Jsonl) =>
        naming switch
        {
            TranscriptNaming.DshSession => IsDshSessionName(fileName),
            TranscriptNaming.CodexRollout => fileName.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)
                || fileName.EndsWith(".jsonl.zst", StringComparison.OrdinalIgnoreCase),
            TranscriptNaming.GeminiSession => Gemini.GeminiDiscovery.IsSessionFileName(fileName),
            TranscriptNaming.OpenCodeDatabase or TranscriptNaming.ZCodeDatabase => false,
            TranscriptNaming.KimiSession => fileName.SequenceEqual("wire.jsonl"),
            TranscriptNaming.GrokBuildSession => fileName.SequenceEqual("updates.jsonl"),
            TranscriptNaming.OmpSession => Omp.OmpDiscovery.IsSessionFileName(fileName),
            TranscriptNaming.AntigravityDatabase => Antigravity.AntigravityPaths.IsDatabaseName(fileName),
            TranscriptNaming.WorkBuddySession => WorkBuddy.WorkBuddyDiscovery.IsSessionFileName(fileName),
            _ => fileName.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase),
        };

    public static bool IsDshSessionName(ReadOnlySpan<char> fileName)
    {
        const string Prefix = "session.v";
        if (!fileName.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var rest = fileName[Prefix.Length..];
        var digits = 0;
        while (digits < rest.Length && char.IsAsciiDigit(rest[digits]))
        {
            digits++;
        }

        rest = rest[digits..];
        return digits > 0
            && (rest.Equals(".jsonl", StringComparison.OrdinalIgnoreCase)
                || rest.Equals(".jsonl.zstd", StringComparison.OrdinalIgnoreCase));
    }

    /// <param name="limit">Newest files kept; <see cref="int.MaxValue"/> also lifts the scan cap (daily history).</param>
    public static List<DiscoveredFile> Enumerate(
        string root,
        TranscriptNaming naming = TranscriptNaming.Jsonl,
        CancellationToken cancellationToken = default,
        int limit = MaxFilesPerRoot)
    {
        if (naming == TranscriptNaming.GeminiSession)
        {
            return Gemini.GeminiDiscovery.Enumerate(root, limit, cancellationToken);
        }

        if (naming is TranscriptNaming.OpenCodeDatabase or TranscriptNaming.ZCodeDatabase)
        {
            return [];
        }

        if (naming == TranscriptNaming.OmpSession)
        {
            return Omp.OmpDiscovery.Enumerate(root, limit, cancellationToken);
        }

        if (naming == TranscriptNaming.AntigravityDatabase)
        {
            return Antigravity.AntigravityDiscovery.Enumerate(root, limit);
        }

        if (naming == TranscriptNaming.WorkBuddySession)
        {
            return WorkBuddy.WorkBuddyDiscovery.Enumerate(root, limit, cancellationToken);
        }

        if (naming is TranscriptNaming.KimiSession or TranscriptNaming.GrokBuildSession)
        {
            return Harnesses.HarnessDiscovery.Enumerate(root, naming == TranscriptNaming.KimiSession, limit, cancellationToken);
        }

        var scanCap = limit == int.MaxValue ? int.MaxValue : MaxScannedEntries;
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            MaxRecursionDepth = MaxDepth,
            IgnoreInaccessible = true,
            AttributesToSkip = 0,
            ReturnSpecialDirectories = false,
        };

        var files = new List<DiscoveredFile>();
        var scanned = 0;
        try
        {
            var enumerable = new FileSystemEnumerable<DiscoveredFile>(
                root,
                static (ref FileSystemEntry entry) => new DiscoveredFile(
                    entry.ToFullPath(), entry.Length, entry.LastWriteTimeUtc.UtcDateTime),
                options)
            {
                ShouldIncludePredicate = (ref FileSystemEntry entry) =>
                    !entry.IsDirectory
                    && (entry.Attributes & FileAttributes.ReparsePoint) == 0
                    && IsTranscriptName(entry.FileName, naming),
                ShouldRecursePredicate = static (ref FileSystemEntry entry) =>
                    (entry.Attributes & FileAttributes.ReparsePoint) == 0,
            };

            foreach (var file in enumerable)
            {
                cancellationToken.ThrowIfCancellationRequested();
                files.Add(file);
                if (++scanned >= scanCap)
                {
                    break;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }

        if (files.Count > limit)
        {
            files.Sort(static (a, b) => b.LastWriteUtc.CompareTo(a.LastWriteUtc));
            files.RemoveRange(limit, files.Count - limit);
        }

        return files;
    }

    /// <summary>
    /// Validates a path reported by a watcher: inside <paramref name="root"/>, within the depth limit, a transcript
    /// name, and no reparse point on the file or on any directory between root and file.
    /// </summary>
    public static bool IsAcceptablePath(string root, string path, TranscriptNaming naming = TranscriptNaming.Jsonl)
    {
        if (naming == TranscriptNaming.GeminiSession)
        {
            return Gemini.GeminiDiscovery.IsSessionPath(root, path);
        }

        if (naming == TranscriptNaming.OmpSession)
        {
            return Omp.OmpDiscovery.IsSessionPath(root, path);
        }

        if (naming == TranscriptNaming.AntigravityDatabase)
        {
            return Antigravity.AntigravityDiscovery.IsDatabasePath(root, path);
        }

        if (naming == TranscriptNaming.WorkBuddySession)
        {
            return WorkBuddy.WorkBuddyDiscovery.IsSessionPath(root, path);
        }

        if (naming is TranscriptNaming.KimiSession or TranscriptNaming.GrokBuildSession)
        {
            return Harnesses.HarnessDiscovery.IsSessionPath(root, path, naming == TranscriptNaming.KimiSession);
        }

        if (!IsTranscriptName(System.IO.Path.GetFileName(path.AsSpan()), naming))
        {
            return false;
        }

        string relative;
        try
        {
            relative = System.IO.Path.GetRelativePath(root, path);
        }
        catch (ArgumentException)
        {
            return false;
        }

        if (System.IO.Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith(".." + System.IO.Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("../", StringComparison.Ordinal))
        {
            return false;
        }

        if (Parsing.PathText.ComponentCount(relative) > MaxDepth + 1)
        {
            return false;
        }

        try
        {
            var current = System.IO.Path.GetFullPath(path);
            var stop = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(root));
            while (current.Length > stop.Length)
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                {
                    return false;
                }

                current = System.IO.Path.GetDirectoryName(current) ?? stop;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }

        return true;
    }
}
