using System.Reflection;
using System.Runtime.InteropServices;

namespace AgentSpeed.Core.IO.Sqlite;

/// <summary>
/// The SQLite C functions Agent Speed uses, bound to the operating system's own library: <c>winsqlite3.dll</c> from
/// System32 on Windows 10 and later, the system <c>libsqlite3</c> elsewhere. No native binary ships with the app.
/// </summary>
internal static unsafe partial class SqliteNative
{
    public const int Ok = 0;
    public const int Error = 1;
    public const int Busy = 5;
    public const int Locked = 6;
    public const int Corrupt = 11;
    public const int CantOpen = 14;
    public const int NotADatabase = 26;
    public const int Row = 100;
    public const int Done = 101;

    public const int OpenReadOnly = 0x00000001;
    public const int OpenReadWrite = 0x00000002;
    public const int OpenCreate = 0x00000004;
    public const int OpenUri = 0x00000040;
    public const int OpenNoMutex = 0x00008000;

    public const int ColumnInteger = 1;
    public const int ColumnFloat = 2;
    public const int ColumnText = 3;
    public const int ColumnBlob = 4;
    public const int ColumnNull = 5;

    private const string Library = "agentspeed_sqlite3";

    /// <summary>SQLITE_TRANSIENT: SQLite copies bound text and blobs before the call returns.</summary>
    public static readonly IntPtr Transient = new(-1);

    private static readonly Lazy<bool> Loaded = new(TryResolveOnce, LazyThreadSafetyMode.ExecutionAndPublication);
    private static IntPtr _handle;

    /// <summary>True when a system SQLite library could be loaded.</summary>
    public static bool IsAvailable => Loaded.Value;

    /// <summary>Candidate libraries in preference order; only trusted system locations on Windows.</summary>
    internal static IEnumerable<(string Name, DllImportSearchPath? SearchPath)> Candidates()
    {
        if (OperatingSystem.IsWindows())
        {
            yield return ("winsqlite3.dll", DllImportSearchPath.System32);
            yield break;
        }

        if (OperatingSystem.IsMacOS())
        {
            yield return ("/usr/lib/libsqlite3.dylib", null);
            yield return ("libsqlite3.dylib", null);
            yield break;
        }

        yield return ("libsqlite3.so.0", null);
        yield return ("libsqlite3.so", null);
        yield return ("libe_sqlite3.so", null);
    }

    private static bool TryResolveOnce()
    {
        foreach (var (name, searchPath) in Candidates())
        {
            if (NativeLibrary.TryLoad(name, typeof(SqliteNative).Assembly, searchPath, out var handle))
            {
                _handle = handle;
                try
                {
                    NativeLibrary.SetDllImportResolver(typeof(SqliteNative).Assembly, Resolve);
                }
                catch (InvalidOperationException)
                {
                    // A resolver is already registered for this assembly; it must then handle this library too.
                }

                return true;
            }
        }

        return false;
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath) =>
        string.Equals(libraryName, Library, StringComparison.Ordinal) ? _handle : IntPtr.Zero;

    [LibraryImport(Library)]
    public static partial int sqlite3_open_v2(byte* filename, out IntPtr db, int flags, IntPtr vfs);

    [LibraryImport(Library)]
    public static partial int sqlite3_close_v2(IntPtr db);

    [LibraryImport(Library)]
    public static partial int sqlite3_busy_timeout(IntPtr db, int milliseconds);

    [LibraryImport(Library)]
    public static partial int sqlite3_extended_result_codes(IntPtr db, int onoff);

    [LibraryImport(Library)]
    public static partial IntPtr sqlite3_errmsg(IntPtr db);

    [LibraryImport(Library)]
    public static partial IntPtr sqlite3_errstr(int code);

    [LibraryImport(Library)]
    public static partial IntPtr sqlite3_libversion();

    [LibraryImport(Library)]
    public static partial int sqlite3_exec(IntPtr db, byte* sql, IntPtr callback, IntPtr argument, out IntPtr errorMessage);

    [LibraryImport(Library)]
    public static partial void sqlite3_free(IntPtr memory);

    [LibraryImport(Library)]
    public static partial long sqlite3_last_insert_rowid(IntPtr db);

    [LibraryImport(Library)]
    public static partial int sqlite3_prepare_v2(IntPtr db, byte* sql, int bytes, out IntPtr statement, IntPtr tail);

    [LibraryImport(Library)]
    public static partial int sqlite3_step(IntPtr statement);

    [LibraryImport(Library)]
    public static partial int sqlite3_reset(IntPtr statement);

    [LibraryImport(Library)]
    public static partial int sqlite3_clear_bindings(IntPtr statement);

    [LibraryImport(Library)]
    public static partial int sqlite3_finalize(IntPtr statement);

    [LibraryImport(Library)]
    public static partial int sqlite3_bind_int64(IntPtr statement, int index, long value);

    [LibraryImport(Library)]
    public static partial int sqlite3_bind_double(IntPtr statement, int index, double value);

    [LibraryImport(Library)]
    public static partial int sqlite3_bind_text(IntPtr statement, int index, byte* text, int bytes, IntPtr destructor);

    [LibraryImport(Library)]
    public static partial int sqlite3_bind_blob(IntPtr statement, int index, void* data, int bytes, IntPtr destructor);

    [LibraryImport(Library)]
    public static partial int sqlite3_bind_null(IntPtr statement, int index);

    [LibraryImport(Library)]
    public static partial int sqlite3_column_type(IntPtr statement, int column);

    [LibraryImport(Library)]
    public static partial long sqlite3_column_int64(IntPtr statement, int column);

    [LibraryImport(Library)]
    public static partial double sqlite3_column_double(IntPtr statement, int column);

    [LibraryImport(Library)]
    public static partial byte* sqlite3_column_text(IntPtr statement, int column);

    [LibraryImport(Library)]
    public static partial void* sqlite3_column_blob(IntPtr statement, int column);

    [LibraryImport(Library)]
    public static partial int sqlite3_column_bytes(IntPtr statement, int column);
}
