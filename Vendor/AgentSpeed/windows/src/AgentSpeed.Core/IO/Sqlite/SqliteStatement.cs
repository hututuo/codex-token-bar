using System.Buffers;
using System.Text;

namespace AgentSpeed.Core.IO.Sqlite;

/// <summary>
/// A prepared statement. Reads run as their own short implicit transaction: <see cref="Reset"/> (or reaching the last
/// row) ends it, so no snapshot outlives a query. Spans returned by column getters are valid until the next step.
/// </summary>
internal sealed unsafe class SqliteStatement : IDisposable
{
    private readonly SqliteConnection _connection;
    private IntPtr _statement;

    internal SqliteStatement(SqliteConnection connection, IntPtr statement)
    {
        _connection = connection;
        _statement = statement;
    }

    private IntPtr Handle => _statement != IntPtr.Zero ? _statement : throw new ObjectDisposedException(nameof(SqliteStatement));

    /// <summary>Advances to the next row; false when there are no more rows.</summary>
    public bool Step()
    {
        var code = SqliteNative.sqlite3_step(Handle);
        return code switch
        {
            SqliteNative.Row => true,
            SqliteNative.Done => false,
            _ => throw _connection.Failure(code),
        };
    }

    /// <summary>Runs a statement that returns no rows, then resets it.</summary>
    public void Run()
    {
        try
        {
            while (Step())
            {
            }
        }
        finally
        {
            Reset();
        }
    }

    public void Reset()
    {
        if (_statement == IntPtr.Zero)
        {
            return;
        }

        SqliteNative.sqlite3_reset(_statement);
        SqliteNative.sqlite3_clear_bindings(_statement);
    }

    public SqliteStatement Bind(int index, long value)
    {
        Check(SqliteNative.sqlite3_bind_int64(Handle, index, value));
        return this;
    }

    public SqliteStatement Bind(int index, double value)
    {
        Check(SqliteNative.sqlite3_bind_double(Handle, index, value));
        return this;
    }

    public SqliteStatement Bind(int index, string? value)
    {
        if (value is null)
        {
            Check(SqliteNative.sqlite3_bind_null(Handle, index));
            return this;
        }

        var length = Encoding.UTF8.GetByteCount(value);
        var rented = length > 512 ? ArrayPool<byte>.Shared.Rent(length) : null;
        try
        {
            Span<byte> buffer = rented ?? stackalloc byte[512];
            var written = Encoding.UTF8.GetBytes(value, buffer);
            fixed (byte* pointer = buffer)
            {
                Check(SqliteNative.sqlite3_bind_text(Handle, index, pointer, written, SqliteNative.Transient));
            }
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }

        return this;
    }

    public SqliteStatement BindBlob(int index, ReadOnlySpan<byte> value)
    {
        // A zero-length blob still needs a non-null pointer, or SQLite binds NULL.
        byte zero = 0;
        fixed (byte* pointer = value)
        {
            Check(SqliteNative.sqlite3_bind_blob(Handle, index, pointer is null ? &zero : pointer, value.Length, SqliteNative.Transient));
        }

        return this;
    }

    public bool IsNull(int column) => SqliteNative.sqlite3_column_type(Handle, column) == SqliteNative.ColumnNull;

    public int ColumnType(int column) => SqliteNative.sqlite3_column_type(Handle, column);

    public long GetInt64(int column) => SqliteNative.sqlite3_column_int64(Handle, column);

    public long? GetNullableInt64(int column) => IsNull(column) ? null : GetInt64(column);

    public double GetDouble(int column) => SqliteNative.sqlite3_column_double(Handle, column);

    public string? GetString(int column)
    {
        if (IsNull(column))
        {
            return null;
        }

        var text = GetUtf8(column);
        return Encoding.UTF8.GetString(text);
    }

    /// <summary>The UTF-8 text of a column (empty for NULL).</summary>
    public ReadOnlySpan<byte> GetUtf8(int column)
    {
        var pointer = SqliteNative.sqlite3_column_text(Handle, column);
        var length = SqliteNative.sqlite3_column_bytes(Handle, column);
        return pointer is null || length <= 0 ? [] : new ReadOnlySpan<byte>(pointer, length);
    }

    public ReadOnlySpan<byte> GetBlob(int column)
    {
        var pointer = SqliteNative.sqlite3_column_blob(Handle, column);
        var length = SqliteNative.sqlite3_column_bytes(Handle, column);
        return pointer is null || length <= 0 ? [] : new ReadOnlySpan<byte>(pointer, length);
    }

    public void Dispose()
    {
        if (_statement == IntPtr.Zero)
        {
            return;
        }

        SqliteNative.sqlite3_finalize(_statement);
        _statement = IntPtr.Zero;
        _connection.Forget(this);
    }

    private void Check(int code)
    {
        if (code != SqliteNative.Ok)
        {
            throw _connection.Failure(code);
        }
    }
}
