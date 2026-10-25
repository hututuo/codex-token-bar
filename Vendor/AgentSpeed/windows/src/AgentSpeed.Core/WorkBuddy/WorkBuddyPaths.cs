namespace AgentSpeed.Core.WorkBuddy;

/// <summary>
/// The data folders of both WorkBuddy editions and their <c>projects</c> roots (METRICS 2, 4.9). The app's
/// <c>WORKBUDDY_CONFIG_DIR</c> and <c>CODEBUDDY_CONFIG_DIR</c> are not honoured: the app sets them only on itself.
/// </summary>
internal static class WorkBuddyPaths
{
    public const string ProjectsFolder = "projects";

    public static bool IsWorkBuddy(SourceKind source) => source is SourceKind.WorkBuddy or SourceKind.WorkBuddyAi;

    /// <summary>The data folder's name below the home folder.</summary>
    public static string FolderName(SourceKind source) => source switch
    {
        SourceKind.WorkBuddy => ".workbuddy",
        SourceKind.WorkBuddyAi => ".workbuddy-ai",
        _ => throw new ArgumentOutOfRangeException(nameof(source), source, null),
    };

    public static string DefaultDataFolder(SourceKind source, string home) => Path.Combine(home, FolderName(source));

    /// <summary>The root to read: a setting names the data folder or its <c>projects</c> folder.</summary>
    public static string ProjectsOf(string dataOrProjects)
    {
        var trimmed = Trim(dataOrProjects);
        return IsProjectsFolder(trimmed) ? trimmed : Path.Combine(trimmed, ProjectsFolder);
    }

    /// <summary>The data folder of a setting or root; its existence decides whether the source is detected (METRICS 2).</summary>
    public static string DataFolderOf(string dataOrProjects)
    {
        var trimmed = Trim(dataOrProjects);
        return IsProjectsFolder(trimmed) && Path.GetDirectoryName(trimmed) is { Length: > 0 } data ? data : trimmed;
    }

    private static bool IsProjectsFolder(string path) =>
        Parsing.PathText.Basename(path).Equals(ProjectsFolder, StringComparison.OrdinalIgnoreCase);

    // Trailing separators go, but a drive root keeps its own ("C:\" never becomes the drive-relative "C:").
    private static string Trim(string path)
    {
        var trimmed = path.TrimEnd('/', '\\');
        return trimmed.Length == 0 || (trimmed.Length == 2 && trimmed[1] == ':') ? path : trimmed;
    }
}
