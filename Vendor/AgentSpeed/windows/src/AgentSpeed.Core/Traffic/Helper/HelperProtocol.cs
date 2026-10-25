using System.Buffers.Binary;

namespace AgentSpeed.Core.Traffic.Helper;

/// <summary>
/// The traffic helper's pipe protocol (WINDOWS-SERVICE 4): little-endian, fixed layouts, read-only. Shared by the helper
/// service and the app; every parser validates sizes, magic and reserved fields and never allocates from peer input.
/// </summary>
public static class HelperProtocol
{
    /// <summary>"ASTH" read as a little-endian <c>u32</c>.</summary>
    public const uint Magic = 0x48545341;

    public const ushort Version = 1;
    public const ushort MinVersion = 1;
    public const ushort MaxVersion = 1;

    public const int RequestSize = 16;
    public const int HeaderSize = 32;
    public const int HelloSize = 40;
    public const int SnapshotHeaderSize = 16;
    public const int EntrySize = 32;
    public const int MaxEntries = 16_384;
    public const int MaxSnapshotPayload = SnapshotHeaderSize + MaxEntries * EntrySize;

    /// <summary>Set on the response <c>type</c> of an error.</summary>
    public const ushort ErrorFlag = 0x8000;

    /// <summary>The pipe name without the <c>\\.\pipe\</c> prefix.</summary>
    public const string PipeName = "AgentSpeed.Traffic";

    public const string PipePath = @"\\.\pipe\" + PipeName;

    public const string ServiceName = "AgentSpeedTraffic";
    public const string ServiceDisplayName = "Agent Speed Traffic Helper";
    public const string ServiceDescription = "Counts network bytes per process for Agent Speed. Reads no content.";
    public const string ExecutableName = "AgentSpeedTrafficHelper.exe";

    /// <summary>Below <c>HKEY_LOCAL_MACHINE</c>.</summary>
    public const string RegistryKey = @"SOFTWARE\AgentSpeed\TrafficHelper";

    public const string EtwSessionName = "AgentSpeed-Traffic";

    /// <summary>The helper version this source tree builds (and the app embeds, <c>bundledHelperVersion</c>).</summary>
    public static HelperVersion BundledVersion { get; } = new(1, 0, 0);

    /// <summary>Raised only for security fixes: an older installed helper is never started.</summary>
    public static HelperVersion MinimumVersion { get; } = new(1, 0, 0);

    /// <summary><c>%ProgramFiles%\Agent Speed\Traffic Helper</c>.</summary>
    public static string InstallFolder(string programFiles) => Path.Combine(programFiles, "Agent Speed", "Traffic Helper");

    public static string InstallPath(string programFiles) => Path.Combine(InstallFolder(programFiles), ExecutableName);
}

/// <summary>Request <c>type</c>.</summary>
public enum HelperRequestType : ushort
{
    Hello = 1,
    Snapshot = 2,
}

/// <summary>Response <c>status</c>.</summary>
public enum HelperStatusCode : uint
{
    Ok = 0,
    UnsupportedVersion = 1,
    BadRequest = 2,
    RateLimited = 3,
    Overloaded = 4,
}

/// <summary>Installer exit codes (WINDOWS-SERVICE 5).</summary>
public enum HelperExitCode
{
    Ok = 0,
    Refused = 1,
    Failed = 2,
}

/// <summary>A helper version, packed as <c>major &lt;&lt; 16 | minor &lt;&lt; 8 | patch</c> on the wire.</summary>
public readonly record struct HelperVersion(int Major, int Minor, int Patch) : IComparable<HelperVersion>
{
    public uint Packed => (uint)(Math.Clamp(Major, 0, 0xFFFF) << 16 | Math.Clamp(Minor, 0, 0xFF) << 8 | Math.Clamp(Patch, 0, 0xFF));

    public static HelperVersion FromPacked(uint packed) => new((int)(packed >> 16), (int)(packed >> 8 & 0xFF), (int)(packed & 0xFF));

    /// <summary>Parses <c>major.minor.patch</c> (ASCII digits only, each part within the packed range).</summary>
    public static bool TryParse(string? text, out HelperVersion version)
    {
        version = default;
        if (string.IsNullOrEmpty(text) || text.Length > 16)
        {
            return false;
        }

        var parts = text.Split('.');
        if (parts.Length != 3)
        {
            return false;
        }

        Span<int> values = stackalloc int[3];
        for (var i = 0; i < 3; i++)
        {
            var part = parts[i];
            if (part.Length is 0 or > 5)
            {
                return false;
            }

            var value = 0;
            foreach (var ch in part)
            {
                if (ch is < '0' or > '9')
                {
                    return false;
                }

                value = value * 10 + (ch - '0');
            }

            values[i] = value;
        }

        if (values[0] > 0xFFFF || values[1] > 0xFF || values[2] > 0xFF)
        {
            return false;
        }

        version = new HelperVersion(values[0], values[1], values[2]);
        return true;
    }

    public int CompareTo(HelperVersion other) => Packed.CompareTo(other.Packed);

    public static bool operator <(HelperVersion a, HelperVersion b) => a.CompareTo(b) < 0;

    public static bool operator >(HelperVersion a, HelperVersion b) => a.CompareTo(b) > 0;

    public static bool operator <=(HelperVersion a, HelperVersion b) => a.CompareTo(b) <= 0;

    public static bool operator >=(HelperVersion a, HelperVersion b) => a.CompareTo(b) >= 0;

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}

/// <summary>The outcome of parsing a request on the server.</summary>
public enum HelperRequestCheck
{
    Valid,

    /// <summary>Wrong size, magic, reserved field or type: answer <c>badRequest</c> and close.</summary>
    BadRequest,

    /// <summary>Well formed but outside <c>[MinVersion, MaxVersion]</c>: answer <c>unsupportedVersion</c> with the hello payload.</summary>
    UnsupportedVersion,
}

/// <summary>A request (exactly 16 bytes): magic, version, type, sequence, reserved = 0.</summary>
public readonly record struct HelperRequest(ushort Version, HelperRequestType Type, uint Sequence)
{
    public void Write(Span<byte> destination)
    {
        if (destination.Length < HelperProtocol.RequestSize)
        {
            throw new ArgumentException("The request needs 16 bytes.", nameof(destination));
        }

        BinaryPrimitives.WriteUInt32LittleEndian(destination, HelperProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(destination[4..], Version);
        BinaryPrimitives.WriteUInt16LittleEndian(destination[6..], (ushort)Type);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[8..], Sequence);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[12..], 0);
    }

    /// <summary>Validates <paramref name="bytes"/> (the whole message as read); <paramref name="request"/> carries the sequence whenever the magic matched.</summary>
    public static HelperRequestCheck TryParse(ReadOnlySpan<byte> bytes, out HelperRequest request)
    {
        request = default;
        if (bytes.Length != HelperProtocol.RequestSize || BinaryPrimitives.ReadUInt32LittleEndian(bytes) != HelperProtocol.Magic)
        {
            return HelperRequestCheck.BadRequest;
        }

        var version = BinaryPrimitives.ReadUInt16LittleEndian(bytes[4..]);
        var type = BinaryPrimitives.ReadUInt16LittleEndian(bytes[6..]);
        var sequence = BinaryPrimitives.ReadUInt32LittleEndian(bytes[8..]);
        var reserved = BinaryPrimitives.ReadUInt32LittleEndian(bytes[12..]);
        request = new HelperRequest(version, (HelperRequestType)type, sequence);
        if (reserved != 0 || type is not ((ushort)HelperRequestType.Hello or (ushort)HelperRequestType.Snapshot))
        {
            return HelperRequestCheck.BadRequest;
        }

        return version is < HelperProtocol.MinVersion or > HelperProtocol.MaxVersion
            ? HelperRequestCheck.UnsupportedVersion
            : HelperRequestCheck.Valid;
    }
}

/// <summary>The 32-byte response header.</summary>
/// <param name="Type">The request type, with <see cref="HelperProtocol.ErrorFlag"/> on error.</param>
/// <param name="Epoch">The service's start time (FILETIME): a new epoch means new counters.</param>
public readonly record struct HelperResponseHeader(
    ushort Version,
    ushort Type,
    HelperStatusCode Status,
    uint Sequence,
    ulong Epoch,
    uint PayloadLength)
{
    public bool IsError => (Type & HelperProtocol.ErrorFlag) != 0;

    public HelperRequestType RequestType => (HelperRequestType)(Type & ~HelperProtocol.ErrorFlag);

    public void Write(Span<byte> destination)
    {
        if (destination.Length < HelperProtocol.HeaderSize)
        {
            throw new ArgumentException("The header needs 32 bytes.", nameof(destination));
        }

        BinaryPrimitives.WriteUInt32LittleEndian(destination, HelperProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(destination[4..], Version);
        BinaryPrimitives.WriteUInt16LittleEndian(destination[6..], Type);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[8..], (uint)Status);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[12..], Sequence);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[16..], Epoch);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[24..], PayloadLength);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[28..], 0);
    }

    /// <summary>
    /// Parses and checks a header against what the client asked: magic, reserved field, sequence echo, request type, a
    /// known status, and a payload length that fits the message (hello: 0 or 40; snapshot: 0 or 16 + 32 × n ≤ the maximum).
    /// </summary>
    public static bool TryParse(ReadOnlySpan<byte> bytes, HelperRequestType expectedType, uint expectedSequence, out HelperResponseHeader header)
    {
        header = default;
        if (bytes.Length != HelperProtocol.HeaderSize || BinaryPrimitives.ReadUInt32LittleEndian(bytes) != HelperProtocol.Magic
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes[28..]) != 0)
        {
            return false;
        }

        header = new HelperResponseHeader(
            BinaryPrimitives.ReadUInt16LittleEndian(bytes[4..]),
            BinaryPrimitives.ReadUInt16LittleEndian(bytes[6..]),
            (HelperStatusCode)BinaryPrimitives.ReadUInt32LittleEndian(bytes[8..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[12..]),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes[16..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[24..]));
        if (header.Sequence != expectedSequence || header.RequestType != expectedType
            || (uint)header.Status > (uint)HelperStatusCode.Overloaded || header.IsError == (header.Status == HelperStatusCode.Ok))
        {
            return false;
        }

        var length = header.PayloadLength;
        if (length == 0)
        {
            return true;
        }

        // An unsupported version still carries the hello payload; other errors carry none.
        if (header.Status == HelperStatusCode.UnsupportedVersion)
        {
            return length == HelperProtocol.HelloSize;
        }

        if (header.Status != HelperStatusCode.Ok)
        {
            return false;
        }

        return expectedType == HelperRequestType.Hello
            ? length == HelperProtocol.HelloSize
            : length >= HelperProtocol.SnapshotHeaderSize && length <= HelperProtocol.MaxSnapshotPayload
                && (length - HelperProtocol.SnapshotHeaderSize) % HelperProtocol.EntrySize == 0;
    }
}

/// <summary>The hello payload (40 bytes).</summary>
/// <param name="Flags">Bit 0: the ETW session is healthy.</param>
public readonly record struct HelperHello(
    ushort MinProtocol,
    ushort MaxProtocol,
    uint HelperVersion,
    uint Flags,
    ulong EventsLost,
    ulong UnparsedEvents,
    ulong EvictedEntries)
{
    public const uint SessionHealthy = 1;

    public bool IsSessionHealthy => (Flags & SessionHealthy) != 0;

    public HelperVersion Version => Helper.HelperVersion.FromPacked(HelperVersion);

    public bool Supports(ushort protocol) => protocol >= MinProtocol && protocol <= MaxProtocol;

    public void Write(Span<byte> destination)
    {
        if (destination.Length < HelperProtocol.HelloSize)
        {
            throw new ArgumentException("The hello payload needs 40 bytes.", nameof(destination));
        }

        BinaryPrimitives.WriteUInt16LittleEndian(destination, MinProtocol);
        BinaryPrimitives.WriteUInt16LittleEndian(destination[2..], MaxProtocol);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[4..], HelperVersion);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[8..], Flags);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[12..], 0);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[16..], EventsLost);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[24..], UnparsedEvents);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[32..], EvictedEntries);
    }

    public static bool TryParse(ReadOnlySpan<byte> bytes, out HelperHello hello)
    {
        hello = default;
        if (bytes.Length != HelperProtocol.HelloSize || BinaryPrimitives.ReadUInt32LittleEndian(bytes[12..]) != 0)
        {
            return false;
        }

        hello = new HelperHello(
            BinaryPrimitives.ReadUInt16LittleEndian(bytes),
            BinaryPrimitives.ReadUInt16LittleEndian(bytes[2..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[8..]),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes[16..]),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes[24..]),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes[32..]));
        return hello.MinProtocol <= hello.MaxProtocol;
    }
}

/// <summary>One snapshot entry (32 bytes): cumulative bytes of one process since the service first saw it.</summary>
/// <param name="CreateTime">The kernel's process create time (FILETIME), as <c>GetProcessTimes</c> reports it.</param>
public readonly record struct HelperEntry(uint Pid, uint Flags, ulong CreateTime, ulong Rx, ulong Tx)
{
    public const uint ExitedFlag = 1;

    public bool Exited => (Flags & ExitedFlag) != 0;

    public void Write(Span<byte> destination)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(destination, Pid);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[4..], Flags);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[8..], CreateTime);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[16..], Rx);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[24..], Tx);
    }

    public static HelperEntry Read(ReadOnlySpan<byte> bytes) => new(
        BinaryPrimitives.ReadUInt32LittleEndian(bytes),
        BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..]),
        BinaryPrimitives.ReadUInt64LittleEndian(bytes[8..]),
        BinaryPrimitives.ReadUInt64LittleEndian(bytes[16..]),
        BinaryPrimitives.ReadUInt64LittleEndian(bytes[24..]));
}

/// <summary>The snapshot payload: sample time (FILETIME), count (≤ 16 384), reserved, then <c>count</c> entries.</summary>
public static class HelperSnapshot
{
    public static int PayloadLength(int count) => HelperProtocol.SnapshotHeaderSize + count * HelperProtocol.EntrySize;

    public static void WriteHeader(Span<byte> destination, ulong sampleTime, int count)
    {
        if (count is < 0 or > HelperProtocol.MaxEntries)
        {
            throw new ArgumentOutOfRangeException(nameof(count));
        }

        BinaryPrimitives.WriteUInt64LittleEndian(destination, sampleTime);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[8..], (uint)count);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[12..], 0);
    }

    /// <summary>
    /// Parses a whole payload into <paramref name="entries"/> (cleared first). False when the count disagrees with the
    /// length, exceeds the maximum or the reserved field is set. Entries with a PID ≤ 4, a zero create time or counters
    /// beyond <see cref="long.MaxValue"/> are dropped (no real process has them).
    /// </summary>
    public static bool TryParse(ReadOnlySpan<byte> payload, List<HelperEntry> entries, out ulong sampleTime)
    {
        ArgumentNullException.ThrowIfNull(entries);
        entries.Clear();
        sampleTime = 0;
        if (payload.Length < HelperProtocol.SnapshotHeaderSize || payload.Length > HelperProtocol.MaxSnapshotPayload)
        {
            return false;
        }

        sampleTime = BinaryPrimitives.ReadUInt64LittleEndian(payload);
        var count = BinaryPrimitives.ReadUInt32LittleEndian(payload[8..]);
        if (count > HelperProtocol.MaxEntries || BinaryPrimitives.ReadUInt32LittleEndian(payload[12..]) != 0
            || payload.Length != PayloadLength((int)count))
        {
            return false;
        }

        for (var i = 0; i < (int)count; i++)
        {
            var entry = HelperEntry.Read(payload.Slice(HelperProtocol.SnapshotHeaderSize + i * HelperProtocol.EntrySize, HelperProtocol.EntrySize));
            if (entry.Pid <= 4 || entry.CreateTime == 0 || entry.Rx > long.MaxValue || entry.Tx > long.MaxValue)
            {
                continue;
            }

            entries.Add(entry);
        }

        return true;
    }
}
