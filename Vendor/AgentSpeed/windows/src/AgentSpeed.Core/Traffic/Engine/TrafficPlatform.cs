namespace AgentSpeed.Core.Traffic.Engine;

public enum TrafficPlatformKind
{
    MacOS,
    Windows,
}

/// <summary>
/// How paths and file names compare on a platform (METRICS 10.5): <c>/</c> and <c>\</c> are equivalent, <c>~</c> is the
/// home folder, <c>%VAR%</c> expands, Windows paths compare case-insensitively; file names drop <c>.exe</c> on Windows
/// and keep their case.
/// </summary>
internal sealed class TrafficPlatform
{
    private readonly KeyValuePair<string, string>[] _environment;
    private readonly string _home;

    public TrafficPlatform(TrafficPlatformKind kind, string home, IReadOnlyDictionary<string, string>? environment = null)
    {
        Kind = kind;
        _home = (home ?? string.Empty).Replace('\\', '/');
        _environment = environment is null
            ? []
            : [.. environment.Select(e => new KeyValuePair<string, string>($"%{e.Key}%", e.Value.Replace('\\', '/')))];
    }

    /// <summary>This Windows user: home folder, <c>%LOCALAPPDATA%</c> and <c>%APPDATA%</c>.</summary>
    public static TrafficPlatform CurrentWindows() => new(
        TrafficPlatformKind.Windows,
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        new Dictionary<string, string>
        {
            ["LOCALAPPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            ["APPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        });

    public TrafficPlatformKind Kind { get; }

    public bool IsWindows => Kind == TrafficPlatformKind.Windows;

    public StringComparison PathComparison => IsWindows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public string Normalize(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return string.Empty;
        }

        var normalized = path.Replace('\\', '/');
        if (normalized.StartsWith("~/", StringComparison.Ordinal))
        {
            normalized = _home + normalized[1..];
        }

        if (normalized.Contains('%'))
        {
            foreach (var (key, value) in _environment)
            {
                normalized = normalized.Replace(key, value, IsWindows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
            }
        }

        normalized = normalized.TrimEnd('/');
        return IsWindows ? normalized.ToLowerInvariant() : normalized;
    }

    /// <summary>The executable's file name without <c>.exe</c> (Windows); case is kept.</summary>
    public string Name(string? executable)
    {
        var path = (executable ?? string.Empty).Replace('\\', '/');
        var slash = path.LastIndexOf('/');
        var name = slash >= 0 ? path[(slash + 1)..] : path;
        if (IsWindows && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            name = name[..^4];
        }

        return name;
    }

    /// <summary><paramref name="path"/> lies under (or is) one of <paramref name="prefixes"/> (already normalized, without a trailing slash).</summary>
    public bool IsUnder(string path, IReadOnlyList<string> prefixes)
    {
        var candidate = Normalize(path) + "/";
        foreach (var prefix in prefixes)
        {
            if (candidate.StartsWith(prefix + "/", StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>Normalizes a prefix list once.</summary>
    public string[] Prefixes(params string[] prefixes) => [.. prefixes.Select(Normalize)];
}
