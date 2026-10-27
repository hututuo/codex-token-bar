using System.Runtime.InteropServices;
using System.Text;

namespace AgentSpeed.Core.IO.Sqlite;

internal sealed class SqliteException(int code, string message) : Exception(message)
{
    /// <summary>Extended result code.</summary>
    public int Code { get; } = code;

    public int PrimaryCode => Code & 0xFF;

    public bool IsBusy => PrimaryCode is SqliteNative.Busy or SqliteNative.Locked;

    /// <summary>The file is not a usable database (corrupt or not SQLite at all).</summary>
    public bool IsCorrupt => PrimaryCode is SqliteNative.Corrupt or SqliteNative.NotADatabase;
}

internal enum SqliteOpenMode
{
    /// <summary>Never writes; without <c>immutable</c>, so concurrent writers stay visible.</summary>
    ReadOnly,
    ReadWriteCreate,

    /// <summary>
    /// <c>immutable=1</c>: reads the database file alone (no WAL, no locks) and creates nothing. Only for a database
    /// nobody has open (METRICS 4.5).
    /// </summary>
    Immutable,
}

/// <summary>
/// One SQLite connection, used by one thread at a time (<c>SQLITE_OPEN_NOMUTEX</c>). Statements it prepared are
/// finalized when it is disposed.
/// </summary>
internal sealed unsafe class SqliteConnection : IDisposable
{
    public const int DefaultBusyTimeoutMs = 2000;

    private readonly HashSet<SqliteStatement> _statements = [];
    private IntPtr _db;

    private SqliteConnection(IntPtr db, string path)
    {
        _db = db;
        Path = path;
    }

    public string Path { get; }

    internal IntPtr Handle => _db != IntPtr.Zero ? _db : throw new ObjectDisposedException(nameof(SqliteConnection));

    public long LastInsertRowId => SqliteNative.sqlite3_last_insert_rowid(Handle);

    public static string? LibraryVersion =>
        SqliteNative.IsAvailable ? Marshal.PtrToStringUTF8(SqliteNative.sqlite3_libversion()) : null;

    public static SqliteConnection Open(string path, SqliteOpenMode mode, int busyTimeoutMs = DefaultBusyTimeoutMs)
    {
        if (!SqliteNative.IsAvailable)
        {
            throw new SqliteException(SqliteNative.CantOpen, "SQLite is not available on this system.");
        }

        var flags = SqliteNative.OpenNoMutex | mode switch
        {
            SqliteOpenMode.ReadOnly => SqliteNative.OpenReadOnly,
            SqliteOpenMode.Immutable => SqliteNative.OpenReadOnly | SqliteNative.OpenUri,
            _ => SqliteNative.OpenReadWrite | SqliteNative.OpenCreate,
        };
        var name = Utf8(mode == SqliteOpenMode.Immutable ? ImmutableUri(path) : path);
        int code;
        IntPtr db;
        fixed (byte* pointer = name)
        {
            code = SqliteNative.sqlite3_open_v2(pointer, out db, flags, IntPtr.Zero);
        }

        if (code != SqliteNative.Ok)
        {
            var message = db != IntPtr.Zero ? Message(db) : "unable to open database";
            if (db != IntPtr.Zero)
            {
                SqliteNative.sqlite3_close_v2(db);
            }

            throw new SqliteException(code, message);
        }

        SqliteNative.sqlite3_extended_result_codes(db, 1);
        SqliteNative.sqlite3_busy_timeout(db, busyTimeoutMs);
        return new SqliteConnection(db, path);
    }

    /// <summary>Runs one or more statements that return no rows.</summary>
    public void Execute(string sql)
    {
        var text = Utf8(sql);
        int code;
        IntPtr error;
        fixed (byte* pointer = text)
        {
            code = SqliteNative.sqlite3_exec(Handle, pointer, IntPtr.Zero, IntPtr.Zero, out error);
        }

        if (code == SqliteNative.Ok)
        {
            return;
        }

        var message = error != IntPtr.Zero ? Marshal.PtrToStringUTF8(error) ?? string.Empty : Message(Handle);
        if (error != IntPtr.Zero)
        {
            SqliteNative.sqlite3_free(error);
        }

        throw new SqliteException(code, message);
    }

    public SqliteStatement Prepare(string sql)
    {
        var text = Utf8(sql);
        int code;
        IntPtr statement;
        fixed (byte* pointer = text)
        {
            code = SqliteNative.sqlite3_prepare_v2(Handle, pointer, text.Length, out statement, IntPtr.Zero);
        }

        if (code != SqliteNative.Ok || statement == IntPtr.Zero)
        {
            if (statement != IntPtr.Zero)
            {
                SqliteNative.sqlite3_finalize(statement);
            }

            throw Failure(code);
        }

        var prepared = new SqliteStatement(this, statement);
        _statements.Add(prepared);
        return prepared;
    }

    /// <summary>Single-value query helper; null when no row or a NULL value.</summary>
    public long? ScalarInt64(string sql)
    {
        using var statement = Prepare(sql);
        return statement.Step() ? statement.GetNullableInt64(0) : null;
    }

    /// <summary>Runs <paramref name="body"/> inside <c>BEGIN IMMEDIATE … COMMIT</c>, rolling back when it throws.</summary>
    public void Transaction(Action body)
    {
        Execute("BEGIN IMMEDIATE");
        try
        {
            body();
            Execute("COMMIT");
        }
        catch
        {
            try
            {
                Execute("ROLLBACK");
            }
            catch (SqliteException)
            {
            }

            throw;
        }
    }

    public void Dispose()
    {
        if (_db == IntPtr.Zero)
        {
            return;
        }

        foreach (var statement in _statements.ToList())
        {
            statement.Dispose();
        }

        SqliteNative.sqlite3_close_v2(_db);
        _db = IntPtr.Zero;
    }

    internal void Forget(SqliteStatement statement) => _statements.Remove(statement);

    internal SqliteException Failure(int code) => new(code, Message(Handle));

    private static string Message(IntPtr db) => Marshal.PtrToStringUTF8(SqliteNative.sqlite3_errmsg(db)) ?? "SQLite error";

    /// <summary><c>file:</c> URI of an absolute path with <c>mode=ro&amp;immutable=1</c>; unusual bytes are percent-encoded.</summary>
    internal static string ImmutableUri(string path)
    {
        var full = System.IO.Path.GetFullPath(path).Replace('\\', '/');
        var builder = new StringBuilder("file:");
        if (!full.StartsWith('/'))
        {
            builder.Append("///");
        }
        else if (full.StartsWith("//", StringComparison.Ordinal))
        {
            builder.Append("//");
        }

        foreach (var b in Encoding.UTF8.GetBytes(full))
        {
            if (char.IsAsciiLetterOrDigit((char)b) || b is (byte)'/' or (byte)':' or (byte)'-' or (byte)'_' or (byte)'.' or (byte)'~')
            {
                builder.Append((char)b);
            }
            else
            {
                builder.Append('%').Append(b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
            }
        }

        return builder.Append("?mode=ro&immutable=1").ToString();
    }

    /// <summary>NUL-terminated UTF-8.</summary>
    private static byte[] Utf8(string text)
    {
        var bytes = new byte[Encoding.UTF8.GetByteCount(text) + 1];
        Encoding.UTF8.GetBytes(text, bytes);
        return bytes;
    }
}
