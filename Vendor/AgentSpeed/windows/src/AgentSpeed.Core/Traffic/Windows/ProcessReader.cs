using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Engine;
using AgentSpeed.Core.Traffic.Monitor;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// The Windows process table (METRICS 10.5): one <c>NtQuerySystemInformation</c> listing per refresh
/// (<c>SystemSessionProcessInformation</c> for this session, else <c>SystemProcessInformation</c>: pid, parent pid,
/// create time, session — no handles opened), limited to this session's processes; the path
/// (<c>QueryFullProcessImageNameW</c>) and, only when a rule needs them, the arguments
/// (<c>NtQueryInformationProcess(ProcessCommandLineInformation)</c>) are read once per identity with
/// <c>PROCESS_QUERY_LIMITED_INFORMATION</c>, after checking the handle's create time against the listing.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed unsafe class ProcessReader : IProcessLister, IDisposable
{
    private const int InitialBuffer = 512 * 1024;
    private const int MaxBuffer = 32 * 1024 * 1024;
    private const int MaxCommandLine = 64 * 1024;

    private readonly uint _session;
    private IntPtr _buffer;
    private int _capacity;
    private bool _allSessions;

    public ProcessReader()
    {
        _session = TrafficNative.ProcessIdToSessionId(TrafficNative.GetCurrentProcessId(), out var session) ? session : uint.MaxValue;
    }

    public bool List(List<ProcessEntry> entries)
    {
        entries.Clear();
        if (IntPtr.Size != 8)
        {
            return false;
        }

        if (_buffer == IntPtr.Zero)
        {
            Grow(InitialBuffer);
        }

        uint status;
        var attempts = 0;
        while (true)
        {
            status = Query(out var needed);
            if (status is not (TrafficNative.StatusInfoLengthMismatch or TrafficNative.StatusBufferTooSmall) || ++attempts > 4)
            {
                break;
            }

            var next = Math.Max(_capacity * 2, (int)Math.Min(MaxBuffer, needed + 64 * 1024L));
            if (next > MaxBuffer || next <= _capacity)
            {
                break;
            }

            Grow(next);
        }

        if (status != 0)
        {
            if (_allSessions)
            {
                return false;
            }

            // The session listing never fit: list every session from now on.
            _allSessions = true;
            return List(entries);
        }

        var offset = 0;
        var base0 = (byte*)_buffer;
        while (offset + TrafficNative.ProcessInfo.MinimumSize <= _capacity)
        {
            var row = base0 + offset;
            var pid = (long)*(IntPtr*)(row + TrafficNative.ProcessInfo.UniqueProcessId);
            var parent = (long)*(IntPtr*)(row + TrafficNative.ProcessInfo.InheritedFromUniqueProcessId);
            var created = *(long*)(row + TrafficNative.ProcessInfo.CreateTime);
            var session = *(uint*)(row + TrafficNative.ProcessInfo.SessionId);
            if (pid > 4 && pid <= int.MaxValue && session == _session && created > 0)
            {
                var start = ProcessIdentity.FromFileTime((uint)pid, (ulong)created).StartUs;
                entries.Add(new ProcessEntry((int)pid, parent is > 0 and <= int.MaxValue ? (int)parent : 0, start));
            }

            var next = *(uint*)(row + TrafficNative.ProcessInfo.NextEntryOffset);
            if (next == 0)
            {
                break;
            }

            offset += (int)next;
        }

        return true;
    }

    /// <summary>
    /// This session's processes only when the system supports it (about half the work of listing every session, whose
    /// services carry most of the threads); otherwise every process, filtered by session while parsing.
    /// </summary>
    private uint Query(out uint needed)
    {
        if (_session != uint.MaxValue && !_allSessions)
        {
            var request = new SessionRequest { SessionId = _session, SizeOfBuffer = (uint)_capacity, Buffer = _buffer };
            var status = TrafficNative.NtQuerySystemInformation(TrafficNative.SystemSessionProcessInformation, (IntPtr)(&request),
                (uint)sizeof(SessionRequest), out needed);
            if (status is 0 or TrafficNative.StatusInfoLengthMismatch or TrafficNative.StatusBufferTooSmall)
            {
                return status;
            }

            _allSessions = true;
        }

        return TrafficNative.NtQuerySystemInformation(TrafficNative.SystemProcessInformation, _buffer, (uint)_capacity, out needed);
    }

    public string? ExecutablePath(in ProcessEntry entry)
    {
        var handle = Open(entry);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var buffer = stackalloc char[1024];
            var size = 1024u;
            return TrafficNative.QueryFullProcessImageName(handle, 0, buffer, ref size) && size > 0 ? new string(buffer, 0, (int)size) : null;
        }
        finally
        {
            TrafficNative.CloseHandle(handle);
        }
    }

    public IReadOnlyList<string>? Arguments(in ProcessEntry entry)
    {
        var handle = Open(entry);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        var size = 4096;
        var memory = IntPtr.Zero;
        try
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                memory = Marshal.AllocHGlobal(size);
                var status = TrafficNative.NtQueryInformationProcess(handle, TrafficNative.ProcessCommandLineInformation, memory, (uint)size, out var needed);
                if (status == 0)
                {
                    return Split((byte*)memory, size);
                }

                Marshal.FreeHGlobal(memory);
                memory = IntPtr.Zero;
                if (status is not (TrafficNative.StatusInfoLengthMismatch or TrafficNative.StatusBufferTooSmall or TrafficNative.StatusBufferOverflow)
                    || needed <= size || needed > MaxCommandLine)
                {
                    return null;
                }

                size = (int)needed;
            }

            return null;
        }
        finally
        {
            if (memory != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(memory);
            }

            TrafficNative.CloseHandle(handle);
        }
    }

    /// <summary>Not read on Windows (METRICS 10.6 step 3 is optional): the step is skipped.</summary>
    public string? WorkingDirectory(in ProcessEntry entry) => null;

    public IReadOnlyCollection<string> OpenFiles(in ProcessEntry entry, long nowMs) => [];

    /// <summary>Windows has no bundles: WorkBuddy is recognized by its executable's name.</summary>
    public string? BundleId(in ProcessEntry entry) => null;

    public void Dispose()
    {
        if (_buffer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_buffer);
            _buffer = IntPtr.Zero;
            _capacity = 0;
        }
    }

    private void Grow(int size)
    {
        if (_buffer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_buffer);
        }

        _buffer = Marshal.AllocHGlobal(size);
        _capacity = size;
    }

    /// <summary>A handle to the listed process, or zero when it cannot be opened or the pid now belongs to another process.</summary>
    private static IntPtr Open(in ProcessEntry entry)
    {
        var handle = TrafficNative.OpenProcess(TrafficNative.ProcessQueryLimitedInformation, false, (uint)entry.Pid);
        if (handle == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        if (TrafficNative.GetProcessTimes(handle, out var created, out _, out _, out _)
            && ProcessIdentity.FromFileTime((uint)entry.Pid, (ulong)created).StartUs == entry.StartUs)
        {
            return handle;
        }

        TrafficNative.CloseHandle(handle);
        return IntPtr.Zero;
    }

    /// <summary>The <c>UNICODE_STRING</c> at the start of <paramref name="memory"/>, split like the C runtime does.</summary>
    private static string[]? Split(byte* memory, int size)
    {
        var length = *(ushort*)memory;
        var text = *(char**)(memory + 8);
        if (length == 0 || text == null)
        {
            return [];
        }

        var start = (byte*)text;
        if (start < memory + 16 || start + length > memory + size)
        {
            return null;
        }

        var line = new string(text, 0, length / 2);
        fixed (char* chars = line)
        {
            var argv = TrafficNative.CommandLineToArgv(chars, out var count);
            if (argv == IntPtr.Zero)
            {
                return null;
            }

            try
            {
                var result = new string[Math.Max(0, count)];
                for (var i = 0; i < result.Length; i++)
                {
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? string.Empty;
                }

                return result;
            }
            finally
            {
                TrafficNative.LocalFree(argv);
            }
        }
    }

    /// <summary><c>SYSTEM_SESSION_PROCESS_INFORMATION</c> (64-bit).</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct SessionRequest
    {
        public uint SessionId;
        public uint SizeOfBuffer;
        public IntPtr Buffer;
    }
}
