namespace AgentSpeed.Core.IO;

/// <summary>Rejects non-local, reparse-point, and cloud-recall paths before a helper opens source data.</summary>
public static class LocalSourcePathPolicy
{
    private const string ExtendedPrefix = @"\\?\";
    private const FileAttributes RecallOnOpen = (FileAttributes)0x0004_0000;
    private const FileAttributes RecallOnDataAccess = (FileAttributes)0x0040_0000;
    private const FileAttributes DeniedAttributes = FileAttributes.ReparsePoint
        | FileAttributes.Offline
        | RecallOnOpen
        | RecallOnDataAccess;

    [System.Runtime.InteropServices.DllImport(
        "kernel32.dll",
        EntryPoint = "GetDriveTypeW",
        CharSet = System.Runtime.InteropServices.CharSet.Unicode,
        ExactSpelling = true)]
    private static extern uint GetDriveType(string rootPathName);

    /// <summary>Drive type values accepted for source files: removable, fixed, CD-ROM, and RAM disk.</summary>
    public static bool IsLocalDriveType(uint driveType) => driveType is 2 or 3 or 5 or 6;

    /// <summary>Validates local drive and existing path components without opening file contents.</summary>
    public static void EnsureReadablePath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        if (!TryGetDriveRoot(path, out var driveRoot) || !IsLocalDriveType(GetDriveType(driveRoot)))
        {
            throw new IOException("source_path_not_local");
        }

        var fullPath = Path.GetFullPath(path);
        var current = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(current))
        {
            throw new IOException("source_path_not_local");
        }

        foreach (var component in fullPath[current.Length..].Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            FileAttributes attributes;
            try
            {
                attributes = File.GetAttributes(current);
            }
            catch (FileNotFoundException)
            {
                return;
            }
            catch (DirectoryNotFoundException)
            {
                return;
            }

            if ((attributes & DeniedAttributes) != 0)
            {
                throw new IOException("source_path_requires_reparse_or_cloud_recall");
            }
        }
    }

    private static bool TryGetDriveRoot(string path, out string root)
    {
        var start = path.StartsWith(ExtendedPrefix, StringComparison.Ordinal) ? ExtendedPrefix.Length : 0;
        if (path.Length >= start + 3
            && ((path[start] is >= 'A' and <= 'Z') || (path[start] is >= 'a' and <= 'z'))
            && path[start + 1] == ':'
            && path[start + 2] is '\\' or '/')
        {
            root = string.Concat(path[start], @":\");
            return true;
        }

        root = string.Empty;
        return false;
    }
}

/// <summary>Optional positioned-read transport for callers that explicitly share local file reads.</summary>
public interface IPositionedReadBackend
{
    /// <summary>
    /// Reads up to <paramref name="count"/> bytes from a local file at <paramref name="offset"/>. The returned
    /// bytes must not exceed the requested count. File identity is the Windows FILE_ID_INFO volume and 128-bit id.
    /// </summary>
    byte[] Read(
        string path,
        ulong volume,
        string fileId,
        ulong offset,
        int count,
        bool probe,
        CancellationToken cancellationToken = default);
}
