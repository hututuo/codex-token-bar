using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.IO;

/// <summary>Identifies one physical file: creation time plus, on Windows, volume serial and file index.</summary>
internal readonly record struct FileIdentity(long CreationTicks, uint Volume, ulong FileIndex)
{
    /// <summary>Null where no stable identity is available (creation time is not reliable on every platform).</summary>
    public static FileIdentity? From(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows())
        {
            return NativeMethods.GetFileInformationByHandle(handle, out var info)
                ? new FileIdentity(
                    ((long)info.CreationTimeHigh << 32) | info.CreationTimeLow,
                    info.VolumeSerialNumber,
                    ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow)
                : null;
        }

        if (OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD())
        {
            return new FileIdentity(File.GetCreationTimeUtc(handle).Ticks, 0, 0);
        }

        return null;
    }
}

internal static partial class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [SupportedOSPlatform("windows")]
    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetFileInformationByHandle(
        SafeFileHandle file, out ByHandleFileInformation information);
}
