using System.Text.RegularExpressions;

namespace AgentSpeed.Core;

public static partial class CodexConfiguredModes
{
    private static readonly Dictionary<string, (long Length, DateTime Modified, ExecutionModes Modes)> Cache = new(StringComparer.Ordinal);

    public static ExecutionModes Read(string? root)
    {
        if (string.IsNullOrEmpty(root)) return ExecutionModes.Empty;
        try
        {
            root = Path.TrimEndingDirectorySeparator(root);
            var config = Path.Combine(Path.GetFileName(root) == "sessions" ? Path.GetDirectoryName(root)! : root, "config.toml");
            var info = new FileInfo(config);
            if (!info.Exists || info.Length > 1024 * 1024 || info.LinkTarget is not null) return ExecutionModes.Empty;
            lock (Cache)
            {
                if (Cache.TryGetValue(config, out var cached) && cached.Length == info.Length && cached.Modified == info.LastWriteTimeUtc)
                    return cached.Modes;
                var modes = Parse(config);
                if (Cache.Count >= 16) Cache.Clear();
                Cache[config] = (info.Length, info.LastWriteTimeUtc, modes);
                return modes;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
        return ExecutionModes.Empty;
    }

    private static ExecutionModes Parse(string config)
    {
        var modes = ExecutionModes.Empty;
        var found = false;
        foreach (var line in File.ReadLines(config))
        {
            var text = line.Trim();
            if (text.StartsWith('#')) continue;
            if (text.Contains("\"\"\"", StringComparison.Ordinal) || text.Contains("'''", StringComparison.Ordinal)) return ExecutionModes.Empty;
            if (text.StartsWith('[')) break;
            var match = TierLine().Match(text);
            if (match.Success)
            {
                if (found) return ExecutionModes.Empty;
                modes = ExecutionModeNative.OpenAiTier(match.Groups[2].Value,
                    ExecutionModeEvidence.Configured, ExecutionModeScope.Configuration);
                found = true;
            }
            else if (text.StartsWith("service_tier", StringComparison.Ordinal)
                && (text.Length == 12 || text[12] is '=' or ' ' or '\t')) return ExecutionModes.Empty;
        }
        return modes;
    }

    [GeneratedRegex("^service_tier\\s*=\\s*([\"'])([A-Za-z0-9][A-Za-z0-9._:-]{0,63})\\1\\s*(?:#.*)?$")]
    private static partial Regex TierLine();
}
