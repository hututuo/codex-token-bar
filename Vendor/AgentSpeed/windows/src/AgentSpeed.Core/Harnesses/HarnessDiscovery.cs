using System.IO.Enumeration;
using AgentSpeed.Core.IO;

namespace AgentSpeed.Core.Harnesses;

internal static class HarnessDiscovery
{
    private static readonly EnumerationOptions Options = new()
    {
        RecurseSubdirectories = false, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint,
    };

    public static List<DiscoveredFile> Enumerate(string root, bool kimi, int limit, CancellationToken cancellationToken)
    {
        var files = new List<DiscoveredFile>();
        var scan = new Scan(limit == int.MaxValue ? int.MaxValue : 200_000, cancellationToken);
        foreach (var workspace in Folders(root, scan))
        {
            foreach (var session in Folders(workspace, scan))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (kimi)
                {
                    foreach (var agent in Folders(Path.Combine(session, "agents"), scan))
                    {
                        Add(Path.Combine(agent, "wire.jsonl"));
                    }
                }
                else
                {
                    Add(Path.Combine(session, "updates.jsonl"));
                }
            }

            if (scan.Full)
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

        void Add(string path)
        {
            try
            {
                if (IsSessionPath(root, path, kimi))
                {
                    var info = new FileInfo(path);
                    files.Add(new DiscoveredFile(path, info.Length, kimi ? info.LastWriteTimeUtc : GrokBuild.GrokFiles.Modified(path, info.LastWriteTimeUtc)));
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    public static bool IsSessionPath(string root, string path, bool kimi)
    {
        if (!TranscriptDiscovery.IsAcceptablePath(root, path, TranscriptNaming.Jsonl))
        {
            return false;
        }

        var parts = Path.GetRelativePath(root, path).Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return parts.All(p => !p.StartsWith('.')) && (kimi
            ? parts.Length == 5 && parts[2] == "agents" && parts[4] == "wire.jsonl"
            : parts.Length == 3 && parts[2] == "updates.jsonl");
    }

    private sealed class Scan(int cap, CancellationToken token)
    {
        public int Visited { get; private set; }
        public bool Full => Visited >= cap;
        public void Visit()
        {
            Visited++;
            token.ThrowIfCancellationRequested();
        }
    }

    private static IEnumerable<string> Folders(string root, Scan scan)
    {
        IEnumerator<(string Path, bool Folder, FileAttributes Attributes)> iterator;
        try
        {
            if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            {
                yield break;
            }

            iterator = new FileSystemEnumerable<(string, bool, FileAttributes)>(root,
                static (ref FileSystemEntry entry) => (entry.ToFullPath(), entry.IsDirectory, entry.Attributes), Options).GetEnumerator();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            yield break;
        }

        using (iterator)
        {
            while (!scan.Full)
            {
                (string Path, bool Folder, FileAttributes Attributes) entry;
                try
                {
                    if (!iterator.MoveNext()) yield break;
                    entry = iterator.Current;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    yield break;
                }

                scan.Visit();
                if (entry.Folder && (entry.Attributes & FileAttributes.ReparsePoint) == 0 && !Path.GetFileName(entry.Path).StartsWith('.'))
                {
                    yield return entry.Path;
                }
            }
        }
    }
}
