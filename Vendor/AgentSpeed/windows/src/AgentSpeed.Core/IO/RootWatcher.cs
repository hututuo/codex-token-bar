namespace AgentSpeed.Core.IO;

/// <summary>
/// File system watcher for one transcript root. Callbacks only record paths; all work happens on the monitor thread.
/// </summary>
internal sealed class RootWatcher : IDisposable
{
    private readonly FileSystemWatcher _watcher;

    private RootWatcher(FileSystemWatcher watcher)
    {
        _watcher = watcher;
    }

    public static RootWatcher? TryCreate(
        string root, TranscriptNaming naming, Action<string> onPath, Action onOverflow)
    {
        FileSystemWatcher? watcher = null;
        try
        {
            var database = naming is TranscriptNaming.OpenCodeDatabase or TranscriptNaming.AntigravityDatabase or TranscriptNaming.ZCodeDatabase;
            watcher = new FileSystemWatcher(root)
            {
                IncludeSubdirectories = !database,
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName,
                InternalBufferSize = 64 * 1024,
            };
            foreach (var filter in Filters(naming))
            {
                watcher.Filters.Add(filter);
            }

            watcher.Changed += (_, e) => onPath(e.FullPath);
            watcher.Created += (_, e) => onPath(e.FullPath);
            watcher.Deleted += (_, e) => onPath(e.FullPath);
            watcher.Renamed += (_, e) =>
            {
                onPath(e.OldFullPath);
                onPath(e.FullPath);
            };
            watcher.Error += (_, _) => onOverflow();
            watcher.EnableRaisingEvents = true;
            return new RootWatcher(watcher);
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException
            or PlatformNotSupportedException or InvalidOperationException)
        {
            watcher?.Dispose();
            return null;
        }
    }

    private static string[] Filters(TranscriptNaming naming) => naming switch
    {
        TranscriptNaming.DshSession => ["*.jsonl", "*.zstd"],
        TranscriptNaming.CodexRollout => ["*.jsonl", "*.zst"],
        TranscriptNaming.GeminiSession => ["*.jsonl", "*.json"],
        TranscriptNaming.OpenCodeDatabase => [OpenCode.OpenCodeDatabase.FileName, OpenCode.OpenCodeDatabase.FileName + "-wal"],
        TranscriptNaming.ZCodeDatabase => ["db.sqlite", "db.sqlite-wal"],
        TranscriptNaming.KimiSession => ["wire.jsonl"],
        TranscriptNaming.GrokBuildSession => ["updates.jsonl", "summary.json"],

        // Never *-shm: readers touch it, so watching it would make every read trigger the next one.
        TranscriptNaming.AntigravityDatabase => ["*.db", "*.db-wal"],
        _ => ["*.jsonl"],
    };

    public void Dispose()
    {
        _watcher.EnableRaisingEvents = false;
        _watcher.Dispose();
    }
}
