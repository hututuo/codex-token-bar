namespace AgentSpeed.Core.Harnesses;

internal static class HarnessPaths
{
    public static string SessionsOf(string root) =>
        Path.GetFileName(Path.TrimEndingDirectorySeparator(root)).Equals("sessions", StringComparison.OrdinalIgnoreCase)
            ? root : Path.Combine(root, "sessions");

    public static string ZCodeDatabase(string root)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            return string.Empty;
        }

        var path = Path.TrimEndingDirectorySeparator(root);
        if (Path.GetExtension(path).Equals(".sqlite", StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }

        string[] candidates = ["db.sqlite", "db/db.sqlite", "cli/db/db.sqlite", ".zcode/cli/db/db.sqlite"];
        foreach (var candidate in candidates)
        {
            var database = Path.Combine(path, candidate.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(database))
            {
                return database;
            }
        }

        return Path.Combine(path, "db.sqlite");
    }
}
