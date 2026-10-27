using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.IO;

/// <summary>Identifies one physical file: creation time plus, on Windows, volume serial and file index.</summary>
internal readonly record struct FileIdentity(long CreationTicks, ulong Volume, ulong FileIndex, string FileId)
{
    /// <summary>Null where no stable identity is available (creation time is not reliable on every platform).</summary>
    public static FileIdentity? From(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!NativeMethods.GetFileInformationByHandle(handle, out var info))
            {
                return null;
            }

            var volume = (ulong)info.VolumeSerialNumber;
            var fileId = string.Empty;
            if (NativeMethods.GetFileInformationByHandleEx(
                    handle,
                    NativeMethods.FileIdInfo,
                    out var fileIdInfo,
                    (uint)Marshal.SizeOf<NativeMethods.FileIdInformation>()))
            {
                Span<byte> bytes = stackalloc byte[16];
                BinaryPrimitives.WriteUInt64LittleEndian(bytes, fileIdInfo.IdentifierLow);
                BinaryPrimitives.WriteUInt64LittleEndian(bytes[8..], fileIdInfo.IdentifierHigh);
                volume = fileIdInfo.VolumeSerialNumber;
                fileId = Convert.ToHexString(bytes);
            }

            return new FileIdentity(
                ((long)info.CreationTimeHigh << 32) | info.CreationTimeLow,
                volume,
                ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow,
                fileId);
        }

        if (OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD())
        {
            return new FileIdentity(File.GetCreationTimeUtc(handle).Ticks, 0, 0, string.Empty);
        }

        return null;
    }
}

internal static partial class NativeMethods
{
    internal const int FileIdInfo = 18;

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileIdInformation
    {
        public ulong VolumeSerialNumber;
        public ulong IdentifierLow;
        public ulong IdentifierHigh;
    }

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

    [SupportedOSPlatform("windows")]
    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        int fileInformationClass,
        out FileIdInformation information,
        uint bufferSize);
}
