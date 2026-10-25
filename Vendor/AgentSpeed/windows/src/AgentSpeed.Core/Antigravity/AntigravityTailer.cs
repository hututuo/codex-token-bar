using System.Diagnostics;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Antigravity;

/// <summary>
/// Size and modification time of a conversation database together with its <c>-wal</c> (METRICS 5.4, 8): the sum of
/// both sizes and the newer time identify it for change detection and the history store.
/// </summary>
internal readonly record struct AntigravityStamp(long DatabaseLength, DateTime DatabaseWriteUtc, long WalLength, DateTime WalWriteUtc)
{
    /// <summary>Both sizes together: any change of either file changes it or the write time.</summary>
    public long Length => DatabaseLength + WalLength;

    /// <summary>The newer of the database and its <c>-wal</c>: the time used for the reading order and the history identity.</summary>
    public DateTime LastWriteUtc => WalWriteUtc > DatabaseWriteUtc ? WalWriteUtc : DatabaseWriteUtc;

    /// <summary>Null when the database does not exist.</summary>
    public static AntigravityStamp? Of(string databasePath)
    {
        try
        {
            var database = new FileInfo(databasePath);
            if (!database.Exists)
            {
                return null;
            }

            var wal = new FileInfo(databasePath + AntigravityPaths.WalSuffix);
            return wal.Exists
                ? new AntigravityStamp(database.Length, database.LastWriteTimeUtc, wal.Length, wal.LastWriteTimeUtc)
                : new AntigravityStamp(database.Length, database.LastWriteTimeUtc, 0, default);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }
}

/// <summary>
/// Follows one conversation database (METRICS 5.4): the first read is complete, later reads take the rows above each
/// table's cursor plus the steps last seen open. The connection follows the open rules of 4.5 and is closed after every
/// read: Windows cannot delete or replace a file another process holds open, so a connection kept between reads would
/// block Antigravity from deleting or rewriting the conversation. Reads and closing are serialized.
/// </summary>
internal sealed class AntigravityTailer : TranscriptTailer, IDisposable
{
    private readonly object _gate = new();
    private AntigravityCursors _cursors = new();
    private AntigravityDatabase? _database;
    private AntigravityStamp? _openedAt;
    private (long Length, DateTime WriteUtc)? _skipUntilChanged;
    private long _lastReadTimestamp;
    private bool _lastReadImmutable;

    public AntigravityTailer(string path)
        : base(path)
    {
    }

    /// <summary>No complete read has finished yet: the next read takes every row (off the live loop, METRICS 5.4).</summary>
    public bool NeedsCompleteRead { get; private set; } = true;

    public bool HasConnection => Volatile.Read(ref _database) is not null;

    /// <summary>The last read used <c>immutable=1</c> (the conversation was closed when it was opened).</summary>
    public bool IsImmutable => Volatile.Read(ref _database)?.IsImmutable ?? _lastReadImmutable;

    /// <summary>The last read found no usable <c>steps</c> table.</summary>
    public bool Unsupported { get; private set; }

    /// <summary><see cref="Stopwatch"/> timestamp of the last read; 0 before the first.</summary>
    public long LastReadTimestamp => Interlocked.Read(ref _lastReadTimestamp);

    /// <summary>An offset above 0 means "already seen at that state": the database is not opened until it changes.</summary>
    public override void StartAt(long offset, StartAlignment alignment = StartAlignment.None)
    {
        Offset = Math.Max(0, offset);
        if (Offset == 0)
        {
            _skipUntilChanged = null;
        }
    }

    /// <summary>
    /// An older database (METRICS 5.4), observed with this combined size and time (<see cref="AntigravityStamp"/>): not
    /// opened until its database or <c>-wal</c> changes.
    /// </summary>
    public void StartAtEnd(long length, DateTime lastWriteUtc)
    {
        Offset = length;
        _skipUntilChanged = (length, lastWriteUtc);
    }

    public override TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default)
    {
        if (sink is not AntigravityBatch batch)
        {
            throw new ArgumentException("An Antigravity database is read into an AntigravityBatch.", nameof(sink));
        }

        lock (_gate)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var stamp = AntigravityStamp.Of(Path) ?? throw new FileNotFoundException("The conversation database is gone.", Path);
            if (_skipUntilChanged is { } skipped)
            {
                if (skipped == (stamp.Length, stamp.LastWriteUtc))
                {
                    return new TailReadResult(false, stamp.Length, stamp.LastWriteUtc, 0);
                }

                _skipUntilChanged = null;
            }

            var wasReset = DetectReplacement();
            Interlocked.Exchange(ref _lastReadTimestamp, Stopwatch.GetTimestamp());
            DropStaleImmutableConnection(stamp);
            if (_database is null)
            {
                _database = AntigravityDatabase.Open(Path);
                _openedAt = stamp;
            }

            Unsupported = _database.Format == AntigravityFormat.Unsupported;
            _lastReadImmutable = _database.IsImmutable;
            if (Unsupported)
            {
                CloseConnection();
                batch.Unsupported = true;
                NeedsCompleteRead = false;
                return new TailReadResult(wasReset, stamp.Length, stamp.LastWriteUtc, 0);
            }

            var complete = _cursors.IsComplete;
            long bytes;
            try
            {
                bytes = _database.Read(_cursors, batch);
            }
            finally
            {
                CloseConnection();
            }

            NeedsCompleteRead = false;
            Offset = stamp.Length;
            var read = complete ? Math.Max(1, stamp.DatabaseLength) : bytes + batch.Count;
            TotalBytesRead += read;
            return new TailReadResult(wasReset, stamp.Length, stamp.LastWriteUtc, read);
        }
    }

    /// <summary>Closes the connection unless a read is running; true when it is closed now.</summary>
    public bool TryCloseConnection()
    {
        if (!Monitor.TryEnter(_gate))
        {
            return false;
        }

        try
        {
            CloseConnection();
            return true;
        }
        finally
        {
            Monitor.Exit(_gate);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            CloseConnection();
        }
    }

    // A new identity of the .db resets the database: parser state and cursors (never the dedupe set).
    private bool DetectReplacement()
    {
        FileIdentity? identity;
        try
        {
            using var handle = Open(Path);
            identity = FileIdentity.From(handle);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            identity = null;
        }

        var replaced = Identity is { } known && identity is { } current && known != current;
        Identity = identity ?? Identity;
        if (!replaced)
        {
            return false;
        }

        CloseConnection();
        var wasRead = !NeedsCompleteRead;
        _cursors = new AntigravityCursors();
        NeedsCompleteRead = true;
        return wasRead;
    }

    // immutable=1 reads the database file alone: drop it on the next change of the .db or once a -wal appears (4.5).
    private void DropStaleImmutableConnection(AntigravityStamp stamp)
    {
        if (_database is { IsImmutable: true }
            && (stamp.WalWriteUtc != default || _openedAt is not { } opened
                || opened.DatabaseLength != stamp.DatabaseLength || opened.DatabaseWriteUtc != stamp.DatabaseWriteUtc))
        {
            CloseConnection();
        }
    }

    private void CloseConnection()
    {
        var database = _database;
        Volatile.Write(ref _database, null);
        _openedAt = null;
        database?.Dispose();
    }
}
