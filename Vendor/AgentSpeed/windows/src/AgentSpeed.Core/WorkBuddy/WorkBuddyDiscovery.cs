using System.IO.Enumeration;
using AgentSpeed.Core.IO;

namespace AgentSpeed.Core.WorkBuddy;

/// <summary>
/// WorkBuddy transcripts below a <c>projects</c> root (METRICS 4.9): main sessions <c>&lt;slug&gt;/&lt;file&gt;.jsonl</c> and
/// sub-agents <c>&lt;slug&gt;/&lt;dir&gt;/subagents/&lt;file&gt;.jsonl</c>, nothing else. The <c>cloud</c> mirrors, every file or
/// folder whose name starts with <c>.</c> and every reparse point are skipped; no other folder is listed.
/// </summary>
internal static class WorkBuddyDiscovery
{
    public const string SubagentsFolder = "subagents";

    private const string CloudFolder = "cloud";
    private const string Extension = ".jsonl";
    private const int MaxScannedFiles = 200_000;

    private static readonly EnumerationOptions ListOptions = new()
    {
        RecurseSubdirectories = false,
        IgnoreInaccessible = true,
        AttributesToSkip = 0,
        ReturnSpecialDirectories = false,
    };

    private static readonly StringComparison FolderComparison =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static bool IsSessionFileName(ReadOnlySpan<char> fileName) =>
        fileName.EndsWith(Extension, StringComparison.Ordinal) && !fileName.StartsWith('.');

    /// <summary>Transcripts under <paramref name="root"/>; when more than <paramref name="limit"/>, the newest ones.</summary>
    public static List<DiscoveredFile> Enumerate(
        string root, int limit = TranscriptDiscovery.MaxFilesPerRoot, CancellationToken cancellationToken = default)
    {
        var cap = limit == int.MaxValue ? int.MaxValue : MaxScannedFiles;
        var files = new List<DiscoveredFile>();
        foreach (var slug in Folders(root))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsSlugName(slug))
            {
                continue;
            }

            var slugPath = Path.Combine(root, slug);
            AddTranscripts(slugPath, files, cap);
            foreach (var session in Folders(slugPath))
            {
                if (files.Count >= cap)
                {
                    break;
                }

                var agents = Path.Combine(slugPath, session, SubagentsFolder);
                if (!session.StartsWith('.') && IsPlainFolder(agents))
                {
                    AddTranscripts(agents, files, cap);
                }
            }

            if (files.Count >= cap)
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
        return parts.Length switch
        {
            2 => IsSlugName(parts[0]),
            4 => IsSlugName(parts[0]) && !parts[1].StartsWith('.') && parts[2].Equals(SubagentsFolder, FolderComparison),
            _ => false,
        };
    }

    /// <summary>
    /// <c>&lt;slug&gt;/&lt;dir&gt;/subagents/&lt;file&gt;</c> below the <c>projects</c> root (METRICS 4.9): the folder
    /// structure only, so a <c>subagents</c> folder above the root does not count.
    /// </summary>
    public static bool IsSubagentPath(string root, string path)
    {
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
        return parts.Length == 4 && parts[2].Equals(SubagentsFolder, FolderComparison);
    }

    private static bool IsSlugName(string name) =>
        !name.StartsWith('.') && !string.Equals(name, CloudFolder, StringComparison.Ordinal);

    private static void AddTranscripts(string folder, List<DiscoveredFile> files, int cap)
    {
        try
        {
            var entries = new FileSystemEnumerable<DiscoveredFile>(
                folder,
                static (ref FileSystemEntry entry) => new DiscoveredFile(
                    entry.ToFullPath(), entry.Length, entry.LastWriteTimeUtc.UtcDateTime),
                ListOptions)
            {
                ShouldIncludePredicate = static (ref FileSystemEntry entry) =>
                    !entry.IsDirectory
                    && (entry.Attributes & FileAttributes.ReparsePoint) == 0
                    && IsSessionFileName(entry.FileName),
            };

            foreach (var file in entries)
            {
                if (files.Count >= cap)
                {
                    return;
                }

                files.Add(file);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    // Names of the folders directly inside <paramref name="path"/> that are not reparse points (symlinks, junctions).
    private static List<string> Folders(string path)
    {
        try
        {
            var entries = new FileSystemEnumerable<string>(
                path, static (ref FileSystemEntry entry) => entry.FileName.ToString(), ListOptions)
            {
                ShouldIncludePredicate = static (ref FileSystemEntry entry) =>
                    entry.IsDirectory && (entry.Attributes & FileAttributes.ReparsePoint) == 0,
            };
            return [.. entries];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return [];
        }
    }

    private static bool IsPlainFolder(string path)
    {
        try
        {
            var info = new DirectoryInfo(path);
            return info.Exists && (info.Attributes & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }
}
