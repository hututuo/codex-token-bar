using System.IO.Enumeration;
using AgentSpeed.Core.IO;

namespace AgentSpeed.Core.Omp;

/// <summary>
/// omp session files (METRICS 4.7): <c>*.jsonl</c> at least one folder below a root, within the depth limit. Every file
/// or folder whose name starts with <c>.</c> (gc staging, rewrite temps) and every reparse point is skipped.
/// </summary>
internal static class OmpDiscovery
{
    private const int MaxScannedEntries = 200_000;

    public static bool IsSessionFileName(ReadOnlySpan<char> fileName) =>
        fileName.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) && !fileName.StartsWith('.');

    /// <summary>Session files under <paramref name="root"/>; when more than <paramref name="limit"/>, the newest ones.</summary>
    public static List<DiscoveredFile> Enumerate(
        string root, int limit = TranscriptDiscovery.MaxFilesPerRoot, CancellationToken cancellationToken = default)
    {
        var scanCap = limit == int.MaxValue ? int.MaxValue : MaxScannedEntries;
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            MaxRecursionDepth = TranscriptDiscovery.MaxDepth,
            IgnoreInaccessible = true,
            AttributesToSkip = 0,
            ReturnSpecialDirectories = false,
        };

        var files = new List<DiscoveredFile>();
        try
        {
            var enumerable = new FileSystemEnumerable<DiscoveredFile>(
                root,
                static (ref FileSystemEntry entry) => new DiscoveredFile(
                    entry.ToFullPath(), entry.Length, entry.LastWriteTimeUtc.UtcDateTime),
                options)
            {
                ShouldIncludePredicate = static (ref FileSystemEntry entry) =>
                    !entry.IsDirectory
                    && (entry.Attributes & FileAttributes.ReparsePoint) == 0
                    && IsSessionFileName(entry.FileName)
                    && Path.TrimEndingDirectorySeparator(entry.Directory).Length
                        > Path.TrimEndingDirectorySeparator(entry.RootDirectory).Length,
                ShouldRecursePredicate = static (ref FileSystemEntry entry) =>
                    (entry.Attributes & FileAttributes.ReparsePoint) == 0 && !entry.FileName.StartsWith('.'),
            };

            foreach (var file in enumerable)
            {
                cancellationToken.ThrowIfCancellationRequested();
                files.Add(file);
                if (files.Count >= scanCap)
                {
                    break;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }

        limit = Math.Max(0, limit);
        if (files.Count > limit)
        {
            files.Sort(static (a, b) => b.LastWriteUtc.CompareTo(a.LastWriteUtc));
            files.RemoveRange(limit, files.Count - limit);
        }

        return files;
    }

    /// <summary>Validates a watcher-reported path with the rules of <see cref="Enumerate"/>.</summary>
    public static bool IsSessionPath(string root, string path)
    {
        if (!TranscriptDiscovery.IsAcceptablePath(root, path, TranscriptNaming.Jsonl)
            || !IsSessionFileName(Path.GetFileName(path.AsSpan())))
        {
            return false;
        }

        string relative;
        try
        {
            relative = Path.GetRelativePath(root, path);
        }
        catch (ArgumentException)
        {
            return false;
        }

        var parts = relative.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 && parts.All(p => !p.StartsWith('.'));
    }

    /// <summary>Components of <paramref name="path"/> below <paramref name="root"/>; 0 when it is not inside it.</summary>
    public static int DepthBelow(string root, string path)
    {
        if (string.IsNullOrEmpty(root))
        {
            return 0;
        }

        try
        {
            var relative = Path.GetRelativePath(root, path);
            if (Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith("..", StringComparison.Ordinal))
            {
                return 0;
            }

            return Parsing.PathText.ComponentCount(relative);
        }
        catch (ArgumentException)
        {
            return 0;
        }
    }
}
