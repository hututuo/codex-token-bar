using System.IO.Enumeration;
using AgentSpeed.Core.IO;

namespace AgentSpeed.Core.Gemini;

/// <summary>
/// Gemini CLI session files at fixed depths below a <c>tmp</c> root (METRICS 4.6): <c>&lt;proj&gt;/chats/&lt;file&gt;</c> and
/// <c>&lt;proj&gt;/chats/&lt;dir&gt;/&lt;file&gt;</c>. Reparse points (symlinks, junctions) are never followed or returned.
/// </summary>
internal static class GeminiDiscovery
{
    private const int MaxScannedFiles = 200_000;

    private static readonly EnumerationOptions ListOptions = new()
    {
        RecurseSubdirectories = false,
        IgnoreInaccessible = true,
        AttributesToSkip = 0,
        ReturnSpecialDirectories = false,
    };

    private enum Level
    {
        Projects,
        Chats,
        SessionFolder,
    }

    public static bool IsSessionFileName(ReadOnlySpan<char> fileName) =>
        fileName.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)
        || fileName.EndsWith(".json", StringComparison.OrdinalIgnoreCase);

    /// <summary>Session files under <paramref name="root"/>; when more than <paramref name="limit"/>, the newest ones.</summary>
    public static List<DiscoveredFile> Enumerate(
        string root, int limit = TranscriptDiscovery.MaxFilesPerRoot, CancellationToken cancellationToken = default)
    {
        var files = new List<DiscoveredFile>();
        foreach (var project in ListEntries(root, Level.Projects))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var chats = Path.Combine(project.Path, GeminiPaths.ChatsFolder);
            if (IsPlainDirectory(chats) && !CollectChats(chats, files, cancellationToken))
            {
                break;
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

    /// <summary>
    /// Validates a watcher-reported path: a session file name at exactly <c>&lt;proj&gt;/chats/&lt;file&gt;</c> or
    /// <c>&lt;proj&gt;/chats/&lt;dir&gt;/&lt;file&gt;</c> below <paramref name="root"/>, a file, and no reparse point on it or on
    /// any directory between root and file.
    /// </summary>
    public static bool IsSessionPath(string root, string path)
    {
        if (!IsSessionFileName(Path.GetFileName(path.AsSpan())))
        {
            return false;
        }

        try
        {
            var relative = Path.GetRelativePath(root, path);
            if (Path.IsPathRooted(relative))
            {
                return false;
            }

            var parts = relative.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length is not (3 or 4) || parts[0] == ".." || parts[1] != GeminiPaths.ChatsFolder)
            {
                return false;
            }

            var file = Path.GetFullPath(path);
            if ((File.GetAttributes(file) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            {
                return false;
            }

            var stop = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
            for (var directory = Path.GetDirectoryName(file);
                 directory is not null && directory.Length > stop.Length;
                 directory = Path.GetDirectoryName(directory))
            {
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                {
                    return false;
                }
            }

            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    // False once the scan limit is reached.
    private static bool CollectChats(string chats, List<DiscoveredFile> files, CancellationToken cancellationToken)
    {
        foreach (var entry in ListEntries(chats, Level.Chats))
        {
            if (entry.IsDirectory)
            {
                cancellationToken.ThrowIfCancellationRequested();
                foreach (var nested in ListEntries(entry.Path, Level.SessionFolder))
                {
                    files.Add(nested.File);
                }
            }
            else
            {
                files.Add(entry.File);
            }

            if (files.Count >= MaxScannedFiles)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsPlainDirectory(string path)
    {
        if (!Directory.Exists(path))
        {
            return false;
        }

        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // Entries that are not reparse points: project folders, chats entries (folders and session files), or session files.
    private static List<Entry> ListEntries(string directory, Level level)
    {
        var entries = new List<Entry>();
        try
        {
            var enumerable = new FileSystemEnumerable<Entry>(
                directory,
                static (ref FileSystemEntry entry) => new Entry(
                    entry.IsDirectory, new DiscoveredFile(entry.ToFullPath(), entry.Length, entry.LastWriteTimeUtc.UtcDateTime)),
                ListOptions)
            {
                ShouldIncludePredicate = level switch
                {
                    Level.Projects => static (ref FileSystemEntry entry) => IsPlain(ref entry) && entry.IsDirectory,
                    Level.Chats => static (ref FileSystemEntry entry) =>
                        IsPlain(ref entry) && (entry.IsDirectory || IsSessionFileName(entry.FileName)),
                    _ => static (ref FileSystemEntry entry) =>
                        IsPlain(ref entry) && !entry.IsDirectory && IsSessionFileName(entry.FileName),
                },
            };

            entries.AddRange(enumerable);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }

        return entries;
    }

    private static bool IsPlain(ref FileSystemEntry entry) => (entry.Attributes & FileAttributes.ReparsePoint) == 0;

    private readonly record struct Entry(bool IsDirectory, DiscoveredFile File)
    {
        public string Path => File.Path;
    }
}
