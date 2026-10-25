namespace AgentSpeed.Core.Omp;

/// <summary>
/// The automatic omp roots (METRICS 2, 4.7): the default <c>sessions</c> folder, then one per named profile. XDG
/// folders count only on macOS; Windows uses <c>%USERPROFILE%</c> alone.
/// </summary>
internal static class OmpPaths
{
    public const string DefaultConfigFolder = ".omp";

    private static readonly StringComparer PathComparer =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// <summary>Roots of this machine, from the process environment.</summary>
    public static IReadOnlyList<string> AutomaticRoots() =>
        Roots(Environment.GetEnvironmentVariable, OperatingSystem.IsMacOS(), UserHome);

    /// <summary>The default root alone (no profiles), as shown in settings.</summary>
    public static string DefaultRoot() => DefaultRoot(Environment.GetEnvironmentVariable, OperatingSystem.IsMacOS(), UserHome);

    /// <param name="environment">Reads one environment variable; null or empty means unset.</param>
    /// <param name="macOS">Whether <c>XDG_DATA_HOME</c> applies.</param>
    public static IReadOnlyList<string> Roots(Func<string, string?> environment, bool macOS, string home)
    {
        var config = ConfigFolder(environment, home);
        var xdgOmp = XdgOmp(environment, macOS);
        var roots = new List<string> { DefaultRoot(environment, macOS, home) };
        var names = new SortedSet<string>(Subdirectories(Path.Combine(config, "profiles")), StringComparer.Ordinal);
        if (xdgOmp is not null)
        {
            names.UnionWith(Subdirectories(Path.Combine(xdgOmp, "profiles")));
        }

        foreach (var name in names)
        {
            var xdgProfile = xdgOmp is null ? null : Path.Combine(xdgOmp, "profiles", name);
            roots.Add(xdgProfile is not null && SafeDirectoryExists(xdgProfile)
                ? Path.Combine(xdgProfile, "sessions")
                : Path.Combine(config, "profiles", name, "agent", "sessions"));
        }

        var seen = new HashSet<string>(PathComparer);
        return [.. roots.Where(seen.Add)];
    }

    private static string DefaultRoot(Func<string, string?> environment, bool macOS, string home)
    {
        if (environment("PI_CODING_AGENT_DIR") is { Length: > 0 } agent)
        {
            return Path.Combine(agent, "sessions");
        }

        return XdgOmp(environment, macOS) is { } xdgOmp && SafeDirectoryExists(xdgOmp)
            ? Path.Combine(xdgOmp, "sessions")
            : Path.Combine(ConfigFolder(environment, home), "agent", "sessions");
    }

    private static string ConfigFolder(Func<string, string?> environment, string home)
    {
        var name = environment("PI_CONFIG_DIR") is { Length: > 0 } custom ? custom : DefaultConfigFolder;
        return Path.Combine(home, name.TrimStart('/', '\\'));
    }

    private static string? XdgOmp(Func<string, string?> environment, bool macOS) =>
        macOS && environment("XDG_DATA_HOME") is { Length: > 0 } xdg ? Path.Combine(xdg, "omp") : null;

    // Folders that are not reparse points (symlinks, junctions).
    private static IEnumerable<string> Subdirectories(string path)
    {
        try
        {
            return new DirectoryInfo(path)
                .EnumerateDirectories("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0 })
                .Where(d => (d.Attributes & FileAttributes.ReparsePoint) == 0)
                .Select(d => d.Name)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return [];
        }
    }

    private static bool SafeDirectoryExists(string path)
    {
        try
        {
            return Directory.Exists(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private static string UserHome => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
}
