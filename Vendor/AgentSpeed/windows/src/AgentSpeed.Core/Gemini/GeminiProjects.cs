using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Gemini;

/// <summary>Project names of Gemini CLI project folders (METRICS 4.6), read once per folder.</summary>
internal static class GeminiProjects
{
    private const string ProjectRootFile = ".project_root";
    private const string RegistryFile = "projects.json";
    private const int MaxCachedFolders = 4096;
    private const int MaxFileBytes = 1 << 20;

    private static readonly ConcurrentDictionary<string, string?> Cache = new(StringComparer.Ordinal);

    /// <summary>
    /// Basename of <c>&lt;projectDir&gt;/.project_root</c>, else the first <c>projects</c> key of
    /// <c>&lt;root&gt;/../projects.json</c> whose value is the folder name, else null.
    /// </summary>
    public static string? ProjectOf(string sessionPath)
    {
        if (GeminiPaths.ProjectDirectoryOf(sessionPath) is not { } directory)
        {
            return null;
        }

        if (Cache.TryGetValue(directory, out var cached))
        {
            return cached;
        }

        var project = LookUp(directory);
        if (Cache.Count >= MaxCachedFolders)
        {
            Cache.Clear();
        }

        Cache[directory] = project;
        return project;
    }

    private static string? LookUp(string directory)
    {
        if (TryRead(Path.Combine(directory, ProjectRootFile)) is { } projectRoot)
        {
            return BasenameOrNull(GeminiText.Strip(Encoding.UTF8.GetString(projectRoot)).ToString());
        }

        var registryFolder = Path.GetDirectoryName(Path.GetDirectoryName(directory));
        if (string.IsNullOrEmpty(registryFolder) || TryRead(Path.Combine(registryFolder, RegistryFile)) is not { } registry)
        {
            return null;
        }

        return RegisteredRoot(registry, Path.GetFileName(directory)) is { } root ? BasenameOrNull(root) : null;
    }

    /// <summary>
    /// The first key of the <c>projects</c> object whose value equals <paramref name="slug"/>, with Python
    /// <c>json.load</c> semantics: a repeated key keeps its first position and its last value.
    /// </summary>
    internal static string? RegisteredRoot(ReadOnlySpan<byte> json, string slug)
    {
        try
        {
            var reader = new Utf8JsonReader(json, JsonScan.Options);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                return null;
            }

            List<(string Root, string? Slug)>? projects = null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var isProjects = reader.ValueTextEquals("projects"u8);
                reader.Read();
                if (!isProjects)
                {
                    JsonScan.SkipValue(ref reader);
                }
                else if (reader.TokenType == JsonTokenType.StartObject)
                {
                    projects = ReadProjects(ref reader);
                }
                else
                {
                    projects = null;
                    JsonScan.SkipValue(ref reader);
                }
            }

            if (reader.Read() || projects is null)
            {
                return null;
            }

            foreach (var (root, value) in projects)
            {
                if (string.Equals(value, slug, StringComparison.Ordinal))
                {
                    return root;
                }
            }

            return null;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static List<(string Root, string? Slug)> ReadProjects(ref Utf8JsonReader reader)
    {
        var entries = new List<(string Root, string? Slug)>();
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var root = reader.GetString()!;
            reader.Read();
            string? slug = null;
            if (reader.TokenType == JsonTokenType.String)
            {
                slug = reader.GetString();
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }

            if (positions.TryGetValue(root, out var index))
            {
                entries[index] = (root, slug);
            }
            else
            {
                positions[root] = entries.Count;
                entries.Add((root, slug));
            }
        }

        return entries;
    }

    private static string? BasenameOrNull(string path) => PathText.Basename(path) is { Length: > 0 } name ? name : null;

    // A regular file (never a symlink or other reparse point) of at most 1 MiB; null when it cannot be read.
    private static byte[]? TryRead(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length > MaxFileBytes)
            {
                return null;
            }

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var content = new MemoryStream((int)info.Length);
            var chunk = new byte[4096];
            int read;
            while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
            {
                content.Write(chunk, 0, read);
                if (content.Length > MaxFileBytes)
                {
                    return null;
                }
            }

            return content.ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }
}
