using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>The Win32 and NT entry points the app-side traffic samplers use (machine counters, process table).</summary>
[SupportedOSPlatform("windows")]
internal static partial class TrafficNative
{
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const int SystemProcessInformation = 5;

    /// <summary>The processes of one session only (<c>SYSTEM_SESSION_PROCESS_INFORMATION</c> in, the same rows out).</summary>
    public const int SystemSessionProcessInformation = 53;
    public const int ProcessCommandLineInformation = 60;
    public const uint StatusInfoLengthMismatch = 0xC0000004;
    public const uint StatusBufferTooSmall = 0xC0000023;
    public const uint StatusBufferOverflow = 0x80000005;

    /// <summary><c>MIB_IF_TABLE_LEVEL.MibIfTableNormal</c>.</summary>
    public const int MibIfTableNormal = 0;

    public const uint IfTypeSoftwareLoopback = 24;
    public const uint IfTypeTunnel = 131;
    public const uint TunnelTypeNone = 0;
    public const uint IfOperStatusUp = 1;

    /// <summary>Layout of <c>MIB_IF_ROW2</c> (netioapi.h), 1352 bytes, the same on x64 and arm64.</summary>
    public static class IfRow2
    {
        public const int Size = 1352;
        public const int InterfaceLuid = 0;
        public const int Alias = 28;
        public const int AliasChars = 257;
        public const int Type = 1128;
        public const int TunnelType = 1132;
        public const int StatusFlags = 1152;
        public const int OperStatus = 1156;
        public const int InOctets = 1208;
        public const int OutOctets = 1280;

        public const byte HardwareInterface = 0x01;
        public const byte FilterInterface = 0x02;
        public const byte EndPointInterface = 0x80;
    }

    /// <summary>Layout of <c>SYSTEM_PROCESS_INFORMATION</c> on 64-bit Windows (stable since NT; documented in part by winternl.h).</summary>
    public static class ProcessInfo
    {
        public const int NextEntryOffset = 0;
        public const int CreateTime = 32;
        public const int UniqueProcessId = 80;
        public const int InheritedFromUniqueProcessId = 88;
        public const int SessionId = 100;
        public const int MinimumSize = 104;
    }

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("iphlpapi.dll")]
    public static partial uint GetIfTable2Ex(int level, out IntPtr table);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("iphlpapi.dll")]
    public static partial void FreeMibTable(IntPtr memory);

    /// <summary>One <c>MIB_IF_ROW2</c> by its <c>InterfaceLuid</c> (set on input), with statistics.</summary>
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("iphlpapi.dll")]
    public static unsafe partial uint GetIfEntry2(byte* row);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("ntdll.dll")]
    public static partial uint NtQuerySystemInformation(int informationClass, IntPtr information, uint length, out uint returnLength);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("ntdll.dll")]
    public static partial uint NtQueryInformationProcess(IntPtr process, int informationClass, IntPtr information, uint length,
        out uint returnLength);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(IntPtr handle);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool QueryFullProcessImageName(IntPtr process, uint flags, char* name, ref uint size);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ProcessIdToSessionId(uint processId, out uint sessionId);

    [LibraryImport("kernel32.dll")]
    public static partial uint GetCurrentProcessId();

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("shell32.dll", EntryPoint = "CommandLineToArgvW", StringMarshalling = StringMarshalling.Utf16)]
    public static unsafe partial IntPtr CommandLineToArgv(char* commandLine, out int count);

    [LibraryImport("kernel32.dll")]
    public static partial IntPtr LocalFree(IntPtr memory);
}
