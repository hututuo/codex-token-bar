using System.IO.Enumeration;
using AgentSpeed.Core.IO;

namespace AgentSpeed.Core.Antigravity;

/// <summary>
/// Conversation databases (METRICS 4.8): regular files directly inside a <c>conversations</c> folder whose name is a
/// UUID followed by <c>.db</c>. Each database's time is the newer of the <c>.db</c> and its <c>-wal</c> (5.4).
/// </summary>
internal static class AntigravityDiscovery
{
    private static readonly EnumerationOptions ListOptions = new()
    {
        RecurseSubdirectories = false,
        IgnoreInaccessible = true,
        AttributesToSkip = 0,
        ReturnSpecialDirectories = false,
    };

    /// <param name="conversations">A store's <c>conversations</c> folder.</param>
    public static List<DiscoveredFile> Enumerate(string conversations, int limit = TranscriptDiscovery.MaxFilesPerRoot)
    {
        var names = new List<string>();
        try
        {
            var enumerable = new FileSystemEnumerable<string>(
                conversations,
                static (ref FileSystemEntry entry) => entry.ToFullPath(),
                ListOptions)
            {
                ShouldIncludePredicate = static (ref FileSystemEntry entry) =>
                    !entry.IsDirectory
                    && (entry.Attributes & FileAttributes.ReparsePoint) == 0
                    && AntigravityPaths.IsDatabaseName(entry.FileName),
            };
            names.AddRange(enumerable);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }

        var files = new List<DiscoveredFile>(names.Count);
        foreach (var path in names)
        {
            if (AntigravityStamp.Of(path) is { } stamp)
            {
                files.Add(new DiscoveredFile(path, stamp.Length, stamp.LastWriteUtc));
            }
        }

        limit = Math.Max(0, limit);
        if (files.Count > limit)
        {
            files.Sort(static (a, b) => b.LastWriteUtc.CompareTo(a.LastWriteUtc));
            files.RemoveRange(limit, files.Count - limit);
        }

        return files;
    }

    /// <summary>A watcher path of a database (or its <c>-wal</c>) directly inside <paramref name="conversations"/>.</summary>
    public static bool IsDatabasePath(string conversations, string path)
    {
        var database = AntigravityPaths.DatabaseOf(path);
        if (!AntigravityPaths.IsDatabaseName(Path.GetFileName(database.AsSpan())))
        {
            return false;
        }

        try
        {
            var folder = Path.GetDirectoryName(Path.GetFullPath(database));
            var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(conversations));
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            return folder is not null
                && string.Equals(Path.TrimEndingDirectorySeparator(folder), root, comparison)
                && File.Exists(database)
                && (File.GetAttributes(database) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }
}
