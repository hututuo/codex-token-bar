using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>The Win32 entry points of the traffic helper client: the pipe, the service control manager and elevation.</summary>
[SupportedOSPlatform("windows")]
internal static partial class HelperNative
{
    public const int ErrorSuccess = 0;
    public const int ErrorFileNotFound = 2;
    public const int ErrorAccessDenied = 5;
    public const int ErrorInvalidHandle = 6;
    public const int ErrorBrokenPipe = 109;
    public const int ErrorPipeBusy = 231;
    public const int ErrorOperationAborted = 995;
    public const int ErrorIoPending = 997;
    public const int ErrorServiceAlreadyRunning = 1056;
    public const int ErrorServiceDoesNotExist = 1060;
    public const int ErrorServiceNotActive = 1062;
    public const int ErrorCancelled = 1223;
    public const int ErrorTimeout = 1460;

    /// <summary><c>FILE_GENERIC_READ | FILE_WRITE_DATA</c>: exactly what the pipe DACL grants an allowed user.</summary>
    public const uint PipeAccess = 0x0012008B;

    public const uint OpenExisting = 3;
    public const uint FileFlagOverlapped = 0x40000000;
    public const uint SecuritySqosPresent = 0x00100000;
    public const uint SecurityIdentification = 0x00010000;

    public const uint WaitObject0 = 0;
    public const uint WaitTimeout = 0x102;
    public const uint Infinite = 0xFFFFFFFF;

    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint Synchronize = 0x00100000;

    public const uint ScManagerConnect = 0x0001;
    public const uint ServiceQueryStatus = 0x0004;
    public const uint ServiceStart = 0x0010;
    public const uint ServiceStop = 0x0020;
    public const uint ServiceControlStop = 0x00000001;
    public const int ScStatusProcessInfo = 0;

    public const uint ServiceStopped = 1;
    public const uint ServiceStartPending = 2;
    public const uint ServiceStopPending = 3;
    public const uint ServiceRunning = 4;

    public const uint SeeMaskNoCloseProcess = 0x00000040;
    public const uint SeeMaskNoAsync = 0x00000100;
    public const uint SeeMaskFlagNoUi = 0x00000400;
    public const int SwHide = 0;

    /// <summary><c>SERVICE_STATUS_PROCESS</c> (winsvc.h).</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct ServiceStatusProcess
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
        public uint ProcessId;
        public uint ServiceFlags;
    }

    /// <summary><c>SERVICE_STATUS</c> (winsvc.h).</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct ServiceStatus
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
    }

    /// <summary><c>SHELLEXECUTEINFOW</c> (shellapi.h); strings are pinned by the caller.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct ShellExecuteInfo
    {
        public uint Size;
        public uint Mask;
        public nint Window;
        public char* Verb;
        public char* File;
        public char* Parameters;
        public char* Directory;
        public int Show;
        public nint InstApp;
        public nint IdList;
        public char* Class;
        public nint ClassKey;
        public uint HotKey;
        public nint IconOrMonitor;
        public nint Process;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial SafeFileHandle CreateFile(
        string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool ReadFile(SafeFileHandle file, byte* buffer, uint count, uint* read, NativeOverlapped* overlapped);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool WriteFile(SafeFileHandle file, byte* buffer, uint count, uint* written, NativeOverlapped* overlapped);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool GetOverlappedResult(
        SafeFileHandle file, NativeOverlapped* overlapped, out uint transferred, [MarshalAs(UnmanagedType.Bool)] bool wait);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool CancelIoEx(SafeFileHandle file, NativeOverlapped* overlapped);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateEventW", SetLastError = true)]
    public static partial SafeWaitHandle CreateEvent(
        nint security, [MarshalAs(UnmanagedType.Bool)] bool manualReset, [MarshalAs(UnmanagedType.Bool)] bool initialState, nint name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ResetEvent(SafeWaitHandle handle);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial uint WaitForSingleObject(SafeHandle handle, uint milliseconds);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetNamedPipeServerProcessId(SafeFileHandle pipe, out uint processId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, char* name, ref uint size);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);

    [LibraryImport("advapi32.dll", EntryPoint = "OpenSCManagerW", SetLastError = true)]
    public static partial SafeServiceHandle OpenSCManager(nint machine, nint database, uint access);

    [LibraryImport("advapi32.dll", EntryPoint = "OpenServiceW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial SafeServiceHandle OpenService(SafeServiceHandle manager, string name, uint access);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool QueryServiceStatusEx(
        SafeServiceHandle service, int level, out ServiceStatusProcess status, uint size, out uint needed);

    [LibraryImport("advapi32.dll", EntryPoint = "StartServiceW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool StartService(SafeServiceHandle service, uint argumentCount, nint arguments);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ControlService(SafeServiceHandle service, uint control, out ServiceStatus status);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseServiceHandle(nint handle);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [LibraryImport("shell32.dll", EntryPoint = "ShellExecuteExW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static unsafe partial bool ShellExecuteEx(ShellExecuteInfo* info);
}

/// <summary>An SCM handle, closed with <c>CloseServiceHandle</c>.</summary>
[SupportedOSPlatform("windows")]
internal sealed class SafeServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public SafeServiceHandle()
        : base(ownsHandle: true)
    {
    }

    protected override bool ReleaseHandle() => HelperNative.CloseServiceHandle(handle);
}
