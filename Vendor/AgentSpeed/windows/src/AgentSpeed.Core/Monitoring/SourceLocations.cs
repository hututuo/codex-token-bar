namespace AgentSpeed.Core.Monitoring;

/// <summary>Resolved root folders of every source (METRICS 2); empty strings stand for "not available".</summary>
/// <param name="OmpRoots">omp <c>sessions</c> folders: the default root and every named profile, or the one chosen.</param>
/// <param name="AntigravityStores">Antigravity store folders (or <c>conversations</c> folders); never a <c>*-backup</c> store.</param>
/// <param name="OmpAutomatic">The omp roots follow the profiles on disk (no folder chosen), so new profiles join later.</param>
/// <param name="WorkBuddyRoot">The WorkBuddy <c>projects</c> folder; empty when not available.</param>
/// <param name="WorkBuddyAiRoot">The WorkBuddy AI <c>projects</c> folder; empty when not available.</param>
internal sealed record SourceLocations(
    string CodexRoot,
    string ClaudeRoot,
    string DshRoot,
    string OpenCodeRoot,
    IReadOnlyList<string> GeminiRoots,
    IReadOnlyList<string>? OmpRoots = null,
    IReadOnlyList<string>? AntigravityStores = null,
    bool OmpAutomatic = false,
    string WorkBuddyRoot = "",
    string WorkBuddyAiRoot = "",
    string ZCodeRoot = "",
    string KimiRoot = "",
    string GrokBuildRoot = "")
{
    public static SourceLocations Resolve(MonitorConfiguration configuration) => new(
        Normalize(configuration.CodexRoot ?? LiveMonitor.DefaultCodexRoot),
        Normalize(configuration.ClaudeRoot ?? LiveMonitor.DefaultClaudeRoot),
        Normalize(configuration.DshRoot ?? LiveMonitor.DefaultDshRoot),
        Normalize(configuration.OpenCodeRoot ?? LiveMonitor.DefaultOpenCodeRoot),
        configuration.GeminiRoot is { } gemini ? [Normalize(gemini)] : [.. LiveMonitor.DefaultGeminiRoots.Select(Normalize)],
        configuration.OmpRoot is { } omp ? [Normalize(omp)] : NormalizeAll(LiveMonitor.DefaultOmpRoots),
        NormalizeAll(LiveMonitor.AntigravityStores(configuration.AntigravityRoot)),
        OmpAutomatic: configuration.OmpRoot is null,
        WorkBuddyRoot: WorkBuddyRootOf(configuration.WorkBuddyRoot ?? LiveMonitor.DefaultWorkBuddyFolder),
        WorkBuddyAiRoot: WorkBuddyRootOf(configuration.WorkBuddyAiRoot ?? LiveMonitor.DefaultWorkBuddyAiFolder),
        ZCodeRoot: Normalize(configuration.ZCodeRoot ?? LiveMonitor.DefaultZCodeRoot),
        KimiRoot: Normalize(Harnesses.HarnessPaths.SessionsOf(configuration.KimiRoot ?? LiveMonitor.DefaultKimiRoot)),
        GrokBuildRoot: Normalize(Harnesses.HarnessPaths.SessionsOf(configuration.GrokBuildRoot ?? LiveMonitor.DefaultGrokBuildRoot)));

    /// <summary>Codex <c>archived_sessions</c>, the sibling of the sessions root (METRICS 8).</summary>
    public string CodexArchiveRoot
    {
        get
        {
            var trimmed = Path.TrimEndingDirectorySeparator(CodexRoot);
            var parent = trimmed.Length > 0 ? Path.GetDirectoryName(trimmed) : null;
            return string.IsNullOrEmpty(parent) ? string.Empty : Path.Combine(parent, "archived_sessions");
        }
    }

    /// <summary>
    /// Transcript roots in family order; Gemini and omp may contribute several, Antigravity one <c>conversations</c>
    /// folder per store, each WorkBuddy edition its <c>projects</c> folder. A path listed twice within a family is returned once.
    /// </summary>
    public IEnumerable<(RootFamily Family, string Path)> FileRoots()
    {
        yield return (RootFamily.Codex, CodexRoot);
        yield return (RootFamily.Claude, ClaudeRoot);
        yield return (RootFamily.DeepSeek, DshRoot);
        foreach (var root in GeminiRoots)
        {
            yield return (RootFamily.Gemini, root);
        }

        foreach (var root in Distinct(OmpRoots ?? []))
        {
            yield return (RootFamily.Omp, root);
        }

        foreach (var store in Distinct((AntigravityStores ?? []).Select(Antigravity.AntigravityPaths.ConversationsOf)))
        {
            yield return (RootFamily.Antigravity, store);
        }

        if (WorkBuddyRoot.Length > 0)
        {
            yield return (RootFamily.WorkBuddy, WorkBuddyRoot);
        }

        if (WorkBuddyAiRoot.Length > 0)
        {
            yield return (RootFamily.WorkBuddyAi, WorkBuddyAiRoot);
        }

        if (KimiRoot.Length > 0)
        {
            yield return (RootFamily.Kimi, KimiRoot);
        }

        if (GrokBuildRoot.Length > 0)
        {
            yield return (RootFamily.GrokBuild, GrokBuildRoot);
        }
    }

    /// <summary>The <c>projects</c> folder for a WorkBuddy data folder or a chosen <c>projects</c> folder (METRICS 4.9).</summary>
    public static string WorkBuddyRootOf(string? dataOrProjects) =>
        string.IsNullOrWhiteSpace(dataOrProjects) ? string.Empty : Normalize(WorkBuddy.WorkBuddyPaths.ProjectsOf(dataOrProjects));

    public static string Normalize(string? root)
    {
        try
        {
            return string.IsNullOrWhiteSpace(root) ? string.Empty : Path.GetFullPath(root);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return string.Empty;
        }
    }

    internal static IReadOnlyList<string> NormalizeAll(IEnumerable<string> roots) =>
        [.. roots.Select(Normalize).Where(r => r.Length > 0)];

    private static IEnumerable<string> Distinct(IEnumerable<string> paths)
    {
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        return paths.Where(p => p.Length > 0 && seen.Add(Path.TrimEndingDirectorySeparator(p)));
    }
}
