namespace AgentSpeed.Core.Antigravity;

/// <summary>
/// Antigravity stores and conversation databases (METRICS 2, 4.8). A store is the language server's
/// <c>--app_data_dir</c> below <c>~/.gemini</c>; its <c>conversations</c> folder holds one database per conversation.
/// </summary>
internal static class AntigravityPaths
{
    public const string ConversationsFolder = "conversations";
    public const string DatabaseExtension = ".db";
    public const string WalSuffix = "-wal";

    /// <summary>The three stores, in this order: CLI, desktop app (and IDE 1.x, extensions), IDE 2.x.</summary>
    public static readonly string[] StoreNames = ["antigravity-cli", "antigravity", "antigravity-ide"];

    private const string BackupSuffix = "-backup";

    /// <summary>The three default stores below <paramref name="geminiFolder"/> (<c>~/.gemini</c>).</summary>
    public static IReadOnlyList<string> DefaultStores(string geminiFolder) =>
        [.. StoreNames.Select(name => Path.Combine(geminiFolder, name))];

    /// <summary>
    /// The folders to read: the setting alone when given, else the default stores; a store named <c>*-backup</c> (or its
    /// <c>conversations</c> folder) is never read.
    /// </summary>
    public static IReadOnlyList<string> Stores(string geminiFolder, string? setting) =>
        [.. (setting is { Length: > 0 } ? [setting] : DefaultStores(geminiFolder)).Select(Trim).Where(c => !IsBackupStore(c))];

    /// <summary>The <c>conversations</c> folder of a store; a path that already names it is used directly.</summary>
    public static string ConversationsOf(string storeOrFolder) =>
        IsConversationsFolder(storeOrFolder) ? storeOrFolder : Path.Combine(storeOrFolder, ConversationsFolder);

    public static bool IsBackupStore(string storeOrFolder)
    {
        var trimmed = Trim(storeOrFolder);
        var store = IsConversationsFolder(trimmed) ? Path.GetDirectoryName(trimmed) ?? string.Empty : trimmed;
        return Parsing.PathText.Basename(store).EndsWith(BackupSuffix, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>A UUID (8-4-4-4-12 hexadecimal digits, any case) followed by <c>.db</c>.</summary>
    public static bool IsDatabaseName(ReadOnlySpan<char> fileName)
    {
        if (fileName.Length != 36 + DatabaseExtension.Length
            || !fileName[36..].Equals(DatabaseExtension, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        for (var i = 0; i < 36; i++)
        {
            var dash = i is 8 or 13 or 18 or 23;
            if (dash ? fileName[i] != '-' : !char.IsAsciiHexDigit(fileName[i]))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>The conversation id: the database file name without <c>.db</c>.</summary>
    public static string ConversationId(string databasePath)
    {
        var name = Path.GetFileName(databasePath);
        return name.EndsWith(DatabaseExtension, StringComparison.OrdinalIgnoreCase) ? name[..^DatabaseExtension.Length] : name;
    }

    /// <summary>
    /// The store folder name of a conversation database (<c>antigravity-cli</c> for
    /// <c>~/.gemini/antigravity-cli/conversations/&lt;id&gt;.db</c>), shown as the project when the conversation names no
    /// workspace; null when the database is not inside a <c>conversations</c> folder.
    /// </summary>
    public static string? StoreNameOf(string databasePath)
    {
        var conversations = Path.GetDirectoryName(databasePath);
        if (conversations is null || !IsConversationsFolder(conversations))
        {
            return null;
        }

        var store = Parsing.PathText.Basename(Path.GetDirectoryName(conversations) ?? string.Empty);
        return store.Length > 0 ? store : null;
    }

    /// <summary>The database a watcher path belongs to: the path itself, or the database of a <c>-wal</c> file.</summary>
    public static string DatabaseOf(string path) =>
        path.EndsWith(DatabaseExtension + WalSuffix, StringComparison.OrdinalIgnoreCase) ? path[..^WalSuffix.Length] : path;

    private static bool IsConversationsFolder(string path) =>
        Parsing.PathText.Basename(path).Equals(ConversationsFolder, StringComparison.OrdinalIgnoreCase);

    private static string Trim(string path) => path.TrimEnd('/', '\\') is { Length: > 0 } trimmed ? trimmed : path;
}
