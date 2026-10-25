namespace AgentSpeed.Core.IO.Sqlite;

/// <summary>
/// Opening someone else's WAL database without ever creating a file (METRICS 4.5): a closed database (WAL header,
/// no <c>-wal</c>) is opened <c>immutable=1</c>, because <c>mode=ro</c> would fail (macOS) or create <c>-wal</c> and
/// <c>-shm</c> (Windows <c>winsqlite3</c>).
/// </summary>
internal static class SqliteReadOnly
{
    public const string WalSuffix = "-wal";

    /// <summary>A WAL-mode database (header bytes 18 and 19 are 2) whose <c>-wal</c> file is gone: nobody has it open.</summary>
    public static bool IsClosedWalDatabase(string path)
    {
        if (File.Exists(path + WalSuffix))
        {
            return false;
        }

        try
        {
            using var handle = TranscriptTailer.Open(path);
            Span<byte> header = stackalloc byte[20];
            return RandomAccess.Read(handle, header, 0) == header.Length
                && header[..16].SequenceEqual("SQLite format 3\0"u8)
                && header[18] == 2
                && header[19] == 2;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// <c>immutable=1</c> for a closed WAL database; otherwise <c>mode=ro</c>, checked with a first query, falling back to
    /// <c>immutable=1</c> only while no <c>-wal</c> exists.
    /// </summary>
    /// <exception cref="SqliteException">The database cannot be opened or read.</exception>
    public static SqliteConnection Open(string path, out bool immutable)
    {
        immutable = IsClosedWalDatabase(path);
        if (immutable)
        {
            return Verified(SqliteConnection.Open(path, SqliteOpenMode.Immutable));
        }

        try
        {
            return Verified(SqliteConnection.Open(path, SqliteOpenMode.ReadOnly));
        }
        catch (SqliteException) when (!File.Exists(path + WalSuffix))
        {
            immutable = true;
            return Verified(SqliteConnection.Open(path, SqliteOpenMode.Immutable));
        }
    }

    // Opening is lazy: the first query is what actually reads (or fails to read) the database.
    private static SqliteConnection Verified(SqliteConnection connection)
    {
        try
        {
            connection.ScalarInt64("SELECT count(*) FROM sqlite_master");
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }
}
