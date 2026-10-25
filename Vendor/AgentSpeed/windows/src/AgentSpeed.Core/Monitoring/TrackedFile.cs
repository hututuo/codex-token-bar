using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.Gemini;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.Omp;
using AgentSpeed.Core.Parsing;
using AgentSpeed.Core.WorkBuddy;

namespace AgentSpeed.Core.Monitoring;

internal enum RootFamily
{
    Codex,
    Claude,
    DeepSeek,
    Gemini,
    Omp,

    /// <summary>One SQLite database per conversation, ordered and tracked like a file (METRICS 5.4).</summary>
    Antigravity,

    /// <summary>The China edition's <c>projects</c> folder (METRICS 4.9).</summary>
    WorkBuddy,

    /// <summary>The international edition's <c>projects</c> folder; same layout and parser as <see cref="WorkBuddy"/>.</summary>
    WorkBuddyAi,

    /// <summary>One SQLite database instead of transcript files (METRICS 5.2).</summary>
    OpenCode,
    ZCode,
    Kimi,
    GrokBuild,
}

/// <summary>Per-family file rules: names, parser and the sources it can produce (METRICS 2 and 4).</summary>
internal static class Families
{
    /// <summary>Families read from transcript files, in a stable order.</summary>
    public static readonly RootFamily[] FileFamilies =
        [
            RootFamily.Codex, RootFamily.Claude, RootFamily.DeepSeek, RootFamily.Gemini, RootFamily.Omp, RootFamily.Antigravity,
            RootFamily.WorkBuddy, RootFamily.WorkBuddyAi, RootFamily.Kimi, RootFamily.GrokBuild,
        ];

    public static TranscriptNaming Naming(RootFamily family) => family switch
    {
        RootFamily.Codex => TranscriptNaming.CodexRollout,
        RootFamily.DeepSeek => TranscriptNaming.DshSession,
        RootFamily.Gemini => TranscriptNaming.GeminiSession,
        RootFamily.Omp => TranscriptNaming.OmpSession,
        RootFamily.Antigravity => TranscriptNaming.AntigravityDatabase,
        RootFamily.WorkBuddy or RootFamily.WorkBuddyAi => TranscriptNaming.WorkBuddySession,
        RootFamily.OpenCode => TranscriptNaming.OpenCodeDatabase,
        RootFamily.ZCode => TranscriptNaming.ZCodeDatabase,
        RootFamily.Kimi => TranscriptNaming.KimiSession,
        RootFamily.GrokBuild => TranscriptNaming.GrokBuildSession,
        _ => TranscriptNaming.Jsonl,
    };

    /// <param name="root">The root the file was found in (omp and WorkBuddy decide sub-agents by the path below it).</param>
    public static TranscriptParser CreateParser(RootFamily family, string path, IDeduper deduper, string root = "") => family switch
    {
        RootFamily.Codex => new CodexParser(path, deduper),
        RootFamily.DeepSeek => new DshParser(path, deduper),
        RootFamily.Gemini => new GeminiParser(path, deduper),
        RootFamily.Claude => new ClaudeParser(path, deduper),
        RootFamily.Omp => new OmpParser(path, deduper, root),
        RootFamily.Antigravity => new AntigravityParser(path, deduper),
        RootFamily.WorkBuddy => new WorkBuddyParser(path, deduper, SourceKind.WorkBuddy, root),
        RootFamily.WorkBuddyAi => new WorkBuddyParser(path, deduper, SourceKind.WorkBuddyAi, root),
        RootFamily.Kimi => new Kimi.KimiParser(path, deduper),
        RootFamily.GrokBuild => new GrokBuild.GrokParser(path, deduper),
        _ => throw new ArgumentOutOfRangeException(nameof(family)),
    };

    /// <summary>Antigravity databases are queried; every other family is a file read by its extension.</summary>
    public static TranscriptTailer CreateTailer(RootFamily family, string path) =>
        family == RootFamily.Antigravity ? new AntigravityTailer(path)
        : family == RootFamily.GrokBuild ? new GrokBuild.GrokTailer(path) : TranscriptTailer.For(path);

    /// <summary>True when any source of the family is enabled.</summary>
    public static bool IsEnabled(RootFamily family, IReadOnlySet<SourceKind> enabled) => family switch
    {
        RootFamily.Codex => enabled.Contains(SourceKind.Codex),
        RootFamily.Claude => enabled.Contains(SourceKind.ClaudeCode) || enabled.Contains(SourceKind.ClaudeDesktop),
        RootFamily.DeepSeek => enabled.Contains(SourceKind.DeepSeek),
        RootFamily.Gemini => enabled.Contains(SourceKind.Gemini),
        RootFamily.Omp => enabled.Contains(SourceKind.Omp),
        RootFamily.Antigravity => enabled.Contains(SourceKind.Antigravity),
        RootFamily.WorkBuddy => enabled.Contains(SourceKind.WorkBuddy),
        RootFamily.WorkBuddyAi => enabled.Contains(SourceKind.WorkBuddyAi),
        RootFamily.OpenCode => enabled.Contains(SourceKind.OpenCode),
        RootFamily.ZCode => enabled.Contains(SourceKind.ZCode),
        RootFamily.Kimi => enabled.Contains(SourceKind.Kimi),
        RootFamily.GrokBuild => enabled.Contains(SourceKind.GrokBuild),
        _ => false,
    };

    public static RootFamily Of(SourceKind source) => source switch
    {
        SourceKind.Codex => RootFamily.Codex,
        SourceKind.DeepSeek => RootFamily.DeepSeek,
        SourceKind.Gemini => RootFamily.Gemini,
        SourceKind.OpenCode => RootFamily.OpenCode,
        SourceKind.Omp => RootFamily.Omp,
        SourceKind.Antigravity => RootFamily.Antigravity,
        SourceKind.WorkBuddy => RootFamily.WorkBuddy,
        SourceKind.WorkBuddyAi => RootFamily.WorkBuddyAi,
        SourceKind.ZCode => RootFamily.ZCode,
        SourceKind.Kimi => RootFamily.Kimi,
        SourceKind.GrokBuild => RootFamily.GrokBuild,
        _ => RootFamily.Claude,
    };
}

/// <summary>One root folder of a source family (Codex sessions, Claude projects shared by Code and Desktop, …).</summary>
internal sealed class SourceRoot(RootFamily family, string path, bool enabled)
{
    public RootFamily Family { get; } = family;

    public TranscriptNaming Naming => Families.Naming(Family);

    public string Path { get; } = path;

    /// <summary>
    /// The folder whose existence makes the source detected (METRICS 2): the root itself, except for WorkBuddy, whose data
    /// folder counts even before its <c>projects</c> folder exists.
    /// </summary>
    public string DetectionPath { get; } =
        (family is RootFamily.WorkBuddy or RootFamily.WorkBuddyAi) && path.Length > 0 ? WorkBuddyPaths.DataFolderOf(path) : path;

    public bool Enabled { get; } = enabled;

    public bool Available { get; set; }

    public bool Seeded { get; set; }
}

/// <summary>A discovered transcript: its tailer, its parser and what was last observed on disk.</summary>
internal sealed class TrackedFile
{
    public TrackedFile(SourceRoot root, string path, IDeduper deduper)
    {
        Root = root;
        Tailer = Families.CreateTailer(root.Family, path);
        Parser = Families.CreateParser(root.Family, path, deduper, root.Path);
    }

    public SourceRoot Root { get; }

    public string Path => Tailer.Path;

    public TranscriptTailer Tailer { get; }

    public TranscriptParser Parser { get; }

    public long KnownLength { get; set; } = -1;

    public DateTime KnownWriteUtc { get; set; }

    public int PushedVersion { get; set; } = -1;

    public bool Unreadable { get; set; }

    /// <summary>Changed while a recent read was still within its rate limit (Antigravity, METRICS 5.4); read on the next poll.</summary>
    public bool Dirty { get; set; }
}
